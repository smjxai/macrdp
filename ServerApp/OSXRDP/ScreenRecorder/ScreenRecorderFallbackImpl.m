#import "ScreenRecorderFallbackImpl.h"
#include <time.h>
#include "osxrdp/packet.h"

// A frame that could not be handed over (no free slot) is offered again once the screen has stopped changing
// for a frame interval plus this margin, and then every kDeferredRetryMsec until there is room for it.
// While the screen keeps changing, the next frame replaces it instead.
static const int64_t kDeferredQuietMarginMsec = 4;
static const int64_t kDeferredRetryMsec = 8;

@implementation ScreenRecorderFallbackImpl {
    CGDisplayStreamRef _displayStream;
    NSDictionary* _recordConfig;
    dispatch_queue_t _recordQue;
    on_record_data _recordCb;
    on_record_cmd _recordCmdCb;
    void* _recordCbUserData;
    void* _recordCmdCbUserData;
    int _displayIdx;

    // The members below are only touched on _recordQue.
    BOOL _running;                          // frames may be handed to _recordCb
    CVPixelBufferRef _deferredPixelBuffer;  // newest frame the data callback had no room for (retained, surface marked in use)
    BOOL _deferredRetryScheduled;
    uint64_t _lastOfferNsec;                // when the last new frame was offered to the data callback
    int64_t _deferredQuietMsec;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _displayStream = NULL;
        _recordConfig = NULL;
        _recordQue = nil;
        _recordCb = NULL;
        _recordCbUserData = NULL;
        _recordCmdCb = NULL;
        _recordCmdCbUserData = NULL;
        _running = NO;
        _deferredPixelBuffer = NULL;
        _deferredRetryScheduled = NO;
        _lastOfferNsec = 0;
        _deferredQuietMsec = 1000 / 30 + kDeferredQuietMarginMsec;
    }
    return self;
}

- (void)dealloc {
    [self dropDeferredFrame];
}

- (void)initializeWithDisplayId:(int)displayId
            DisplayIndex:(int)displayIdx
            RecordWidth:(int)width
            RecordHeight:(int)height
            RecordFramerate:(int)framerate
            RecordFormat:(int)recordFormat
            RecordDataCallback:(on_record_data)recordCb
            RecordDataCallbackUserData:(void*)userData
            RecordCmdCallback:(on_record_cmd)recordCmdCb
            RecordCmdCallbackUserData:(void*)userData2 {

    CGRect destRect = CGRectMake(0, 0, width, height);
    CFDictionaryRef destRectDict = CGRectCreateDictionaryRepresentation(destRect);

    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

    if (framerate <= 0) {
        framerate = 30;
    }

    float frameTime = 100.0f / (framerate * 105);
    _deferredQuietMsec = 1000 / framerate + kDeferredQuietMarginMsec;

    _recordConfig = @{
        (__bridge NSString*)kCGDisplayStreamShowCursor : @NO,
        (__bridge NSString*)kCGDisplayStreamQueueDepth : @4,                // one more than the minimum: a frame can be kept until there is room for it
        (__bridge NSString*)kCGDisplayStreamMinimumFrameTime : @(frameTime),
        (__bridge NSString*)kCGDisplayStreamDestinationRect : (__bridge_transfer NSDictionary*)destRectDict,
        (__bridge NSString*)kCGDisplayStreamPreserveAspectRatio : @NO,      // 비율 무시하고 녹화 (늘리기)
        //(__bridge NSString*)kCGDisplayStreamColorSpace : (__bridge id)sRGB, // 이 설정이 없으면 물빠진 색감이 나옴
    };

    CGColorSpaceRelease(sRGB);

    CGDisplayStreamFrameAvailableHandler handler = ^(CGDisplayStreamFrameStatus status,
                                                     uint64_t displayTime,
                                                     IOSurfaceRef frameSurface,
                                                     CGDisplayStreamUpdateRef updateRef) {
        if (status == kCGDisplayStreamFrameStatusFrameComplete && frameSurface != NULL) {
            // 녹화 콜백
            [self processFrame:frameSurface displayTime:displayTime update:updateRef];
        }
        else if (status == kCGDisplayStreamFrameStatusStopped) {
            // 녹화 상태 콜백
            [self processStreamStopped];
        }
    };

    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    _recordQue = dispatch_queue_create("osxrdp.fallback_record", attr);

    int format = kCVPixelFormatType_32BGRA; // 일반 bitmap
    if (recordFormat == OSXRDP_RECORDFORMAT_NV12_PACKED || recordFormat == OSXRDP_RECORDFORMAT_NV12_ALIGNED) {
        format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange; // h264
    }
    else if (recordFormat == OSXRDP_RECORDFORMAT_RFX) {
        format = kCVPixelFormatType_32BGRA; // rfx (BGRA 캡처 후 상위에서 YUV444 변환)
    }

    _displayStream = CGDisplayStreamCreateWithDispatchQueue(displayId, width, height, format, (__bridge CFDictionaryRef)_recordConfig, _recordQue, handler);
    if (_displayStream == NULL) {
        // ????????
        usleep(5000);
        _displayStream = CGDisplayStreamCreateWithDispatchQueue(displayId, width, height, format, (__bridge CFDictionaryRef)_recordConfig, _recordQue, handler);
    }

    _recordCb = recordCb;
    _recordCbUserData = userData;
    _recordCmdCb = recordCmdCb;
    _recordCmdCbUserData = userData2;
    _displayIdx = displayIdx;
}

- (BOOL)start {
    if (_recordQue == nil) {
         NSLog(@"[ScreenRecorderFallbackImpl::start] recordQue is NULL\n");
         return FALSE;
    }

    if (_displayStream == NULL) {
        NSLog(@"[ScreenRecorderFallbackImpl::start] displayStream is NULL\n");
        return FALSE;
    }

    NSLog(@"[ScreenRecorderFallbackImpl::start] before start record\n");

    dispatch_sync(_recordQue, ^{
        self->_running = YES;
    });

    CGError err = CGDisplayStreamStart(_displayStream);
    if (err != kCGErrorSuccess) {
        NSLog(@"[ScreenRecorderFallbackImpl::start] Failed to start stream: %d\n", err);

        dispatch_sync(_recordQue, ^{
            self->_running = NO;
        });

        CFRelease(_displayStream);
        _displayStream = NULL;
        return FALSE;
    }

    NSLog(@"[ScreenRecorderFallbackImpl::start] start record\n");
    return TRUE;
}

- (BOOL)stop {
    if (_displayStream == NULL) return YES;

    CGDisplayStreamStop(_displayStream);

    if (_recordQue) {
        // From here on no frame may reach the callback: the owner releases the shared memory once stop returns.
        dispatch_sync(_recordQue, ^{
            self->_running = NO;
            [self dropDeferredFrame];
        });
    }

    CFRelease(_displayStream);
    _displayStream = NULL;

    NSLog(@"[ScreenRecorderFallbackImpl::stop] Stop Record\n");

    return YES;
}

- (void)processFrame:(IOSurfaceRef)ioSurface displayTime:(uint64_t)displayTime update:(CGDisplayStreamUpdateRef)updateRef {
    if (_recordCb == NULL || _running == NO) return;

    CVPixelBufferRef pixelBuffer = NULL;

    CVReturn cvErr = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, ioSurface, NULL, &pixelBuffer);
    if (cvErr != kCVReturnSuccess || pixelBuffer == NULL) {
        return;
    }

    // dirty 영역을 조회
    size_t dirtyRectsCnt= 0;
    const CGRect* dirtyRects = CGDisplayStreamUpdateGetRects(updateRef, kCGDisplayStreamUpdateDirtyRects, &dirtyRectsCnt);

    // 녹화 콜백 전달
    int taken = [self publishPixelBuffer:pixelBuffer dirtyRects:dirtyRects dirtyRectsCnt:(int)dirtyRectsCnt];

    _lastOfferNsec = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

    // Either way the frame kept so far is outdated now.
    [self dropDeferredFrame];

    if (taken == 0) {
        // No room for the frame. Keep it and offer it again later, so the newest picture always reaches
        // the client even when the screen stops changing right after.
        // The use count tells the display stream not to reuse the surface for new frames meanwhile.
        IOSurfaceIncrementUseCount(ioSurface);
        _deferredPixelBuffer = CVPixelBufferRetain(pixelBuffer);

        [self scheduleDeferredRetryAfterMsec:_deferredQuietMsec];
    }

    CVPixelBufferRelease(pixelBuffer);
}

// Hands the frame to the data callback. _recordQue only.
// Returns 1 when the frame was taken (or cannot be used at all), 0 when there was no room for it.
- (int)publishPixelBuffer:(CVPixelBufferRef)pixelBuffer dirtyRects:(const CGRect*)dirtyRects dirtyRectsCnt:(int)dirtyRectsCnt {
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return 1;
    }

    int taken = _recordCb(pixelBuffer, dirtyRects, dirtyRectsCnt, _recordCbUserData, _displayIdx);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    return taken != 0 ? 1 : 0;
}

// _recordQue only (or when nothing else can reference the object any more).
- (void)dropDeferredFrame {
    if (_deferredPixelBuffer == NULL) {
        return;
    }

    IOSurfaceRef surface = CVPixelBufferGetIOSurface(_deferredPixelBuffer);
    if (surface != NULL) {
        IOSurfaceDecrementUseCount(surface);
    }

    CVPixelBufferRelease(_deferredPixelBuffer);
    _deferredPixelBuffer = NULL;
}

// _recordQue only.
- (void)scheduleDeferredRetryAfterMsec:(int64_t)delayMsec {
    dispatch_queue_t que = _recordQue;
    if (que == nil || _deferredRetryScheduled == YES) {
        return;
    }

    if (delayMsec < 1) {
        delayMsec = 1;
    }

    _deferredRetryScheduled = YES;

    __weak ScreenRecorderFallbackImpl* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMsec * NSEC_PER_MSEC)), que, ^{
        [weakSelf retryDeferredFrame];
    });
}

// _recordQue only.
- (void)retryDeferredFrame {
    _deferredRetryScheduled = NO;

    if (_running == NO) {
        [self dropDeferredFrame];
        return;
    }

    if (_deferredPixelBuffer == NULL || _recordCb == NULL) {
        return;
    }

    // The screen is still changing: a newer frame is about to arrive and takes the place of this one.
    int64_t quietMsec = (int64_t)((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - _lastOfferNsec) / NSEC_PER_MSEC);
    if (quietMsec < _deferredQuietMsec) {
        [self scheduleDeferredRetryAfterMsec:_deferredQuietMsec - quietMsec];
        return;
    }

    if ([self publishPixelBuffer:_deferredPixelBuffer dirtyRects:NULL dirtyRectsCnt:OSXRDP_DIRTYCNT_RETRY] == 0) {
        // still no room
        [self scheduleDeferredRetryAfterMsec:kDeferredRetryMsec];
        return;
    }

    [self dropDeferredFrame];
}

- (void)processStreamStopped {
    if (_recordCmdCb != NULL) {
        _recordCmdCb(OSXRDP_RECORDCMD_STOPPED, _recordCmdCbUserData);
    }
}

@end
