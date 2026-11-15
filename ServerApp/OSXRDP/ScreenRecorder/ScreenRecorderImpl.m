#import "ScreenRecorderImpl.h"

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#include <unistd.h>
#include <time.h>
#include "osxrdp/packet.h"
#include "osxrdp/screenrecordshm.h"

// Upper bounds for the system calls below, so a call that never answers cannot hang the ipc thread forever.
static const int64_t kShareableContentTimeoutSec = 10;
static const int64_t kStartCaptureTimeoutSec = 10;
static const int64_t kStopCaptureTimeoutSec = 5;

// A display that was just created (virtual monitor) can be missing from SCShareableContent for a moment.
static const int kDisplayLookupRetryCnt = 10;
static const useconds_t kDisplayLookupRetryIntervalUsec = 200 * 1000;

// ScreenCaptureKit only sends an image when the screen changes. If nothing has changed this long after the
// stream started, a snapshot is published instead so the client never sits on a black screen.
static const int64_t kFirstFrameGraceMsec = 500;
static const int64_t kFirstFrameRetryMsec = 1000;
static const int kFirstFrameMaxCheckCnt = 5;

// A frame that could not be handed over (no free slot) is offered again once the screen has stopped changing
// for a frame interval plus this margin, and then every kDeferredRetryMsec until there is room for it.
// While the screen keeps changing, the next frame replaces it instead.
static const int64_t kDeferredQuietMarginMsec = 4;
static const int64_t kDeferredRetryMsec = 8;

// Returns
//   -1 : the sample has no image to publish (idle, blank, suspended, stopped ...)
//    0 : the whole frame must be redrawn
//   >0 : number of dirty rects written to rects
static int GetFrameInfoFromSampleBuffer(CMSampleBufferRef sampleBuffer, CGRect* rects, NSInteger* statusOut) {
    *statusOut = -1;

    CFArrayRef arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (arr == NULL || CFArrayGetCount(arr) == 0) {
        return -1;
    }

    CFDictionaryRef att = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, 0);
    if (att == NULL) {
        return -1;
    }

    NSNumber* status = (__bridge NSNumber*)CFDictionaryGetValue(att, (__bridge CFStringRef)SCStreamFrameInfoStatus);
    if (status == nil) {
        return -1;
    }

    SCFrameStatus frameStatus = (SCFrameStatus)status.integerValue;
    *statusOut = (NSInteger)frameStatus;

    // The first frame after the stream starts is reported as "started", not "complete", and it carries the
    // whole screen. Dropping it leaves the client with nothing to draw until the screen changes.
    if (frameStatus == SCFrameStatusStarted) {
        return 0;
    }

    if (frameStatus != SCFrameStatusComplete) {
        return -1;
    }

    CFArrayRef dirtyArr = (CFArrayRef)CFDictionaryGetValue(att, (__bridge CFStringRef)SCStreamFrameInfoDirtyRects);
    if (dirtyArr == NULL) {
        return 0;
    }

    int dirtyAreaCnt = (int)CFArrayGetCount(dirtyArr);
    if (dirtyAreaCnt > MAX_DIRTY_COUNT) return 0;

    for (int i = 0; i < dirtyAreaCnt; i++) {
        CFTypeRef element = CFArrayGetValueAtIndex(dirtyArr, i);
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)element, &(rects[i]));
    }

    return dirtyAreaCnt;
}

@implementation ScreenRecorderImpl {
    SCContentFilter* _recordFilter;
    SCStreamConfiguration* _recordConfig;
    dispatch_queue_t _recordQue;
    SCStream* _recordStream;
    on_record_data _recordCb;
    on_record_cmd _recordCmdCb;
    void* _recordCbUserData;
    void* _recordCmdCbUserData;
    int _displayIdx;
    int _displayId;
    int _width;
    int _height;
    OSType _pixelFormat;

    // The members below are only touched on _recordQue.
    BOOL _running;              // frames may be handed to _recordCb
    BOOL _streamStopped;        // the stream stopped by itself (didStopWithError)
    BOOL _snapshotPublished;
    int _firstFrameCheckCnt;
    CMSampleBufferRef _deferredSample;  // newest frame the data callback had no room for (retained)
    BOOL _deferredRetryScheduled;
    uint64_t _lastOfferNsec;            // when the last new frame was offered to the data callback
    int64_t _deferredQuietMsec;
    uint64_t _startedFrames;
    uint64_t _completeFrames;
    uint64_t _idleFrames;
    uint64_t _blankFrames;
    uint64_t _suspendedFrames;

    CGRect _dirtyRectBuffer[MAX_DIRTY_COUNT];
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _recordFilter = nil;
        _recordConfig = nil;
        _recordQue = nil;
        _recordStream = nil;
        _recordCb = NULL;
        _recordCbUserData = NULL;
        _recordCmdCb = NULL;
        _recordCmdCbUserData = NULL;
        _running = NO;
        _streamStopped = NO;
        _deferredSample = NULL;
        _deferredRetryScheduled = NO;
        _lastOfferNsec = 0;
        _deferredQuietMsec = 1000 / 30 + kDeferredQuietMarginMsec;
    }

    return self;
}

- (void)dealloc {
    if (_deferredSample != NULL) {
        CFRelease(_deferredSample);
        _deferredSample = NULL;
    }
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

    SCDisplay* display = [self getDisplayFromDisplayId: displayId];
    if (display == nil) return;

    _recordFilter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
    if (_recordFilter == nil) return;

    // 녹화 설정 (해상도, 프레임 등)
    _recordConfig = [[SCStreamConfiguration alloc] init];
    _recordConfig.width = width;
    _recordConfig.height = height;
    // One more than the minimum of 3: a frame that could not be handed over is kept until there is room for it,
    // and ScreenCaptureKit stalls when it runs out of surfaces.
    _recordConfig.queueDepth = 4;

    //_recordConfig.colorSpaceName = kCGColorSpaceSRGB;

    if (recordFormat == OSXRDP_RECORDFORMAT_NV12_PACKED || recordFormat == OSXRDP_RECORDFORMAT_NV12_ALIGNED) {
        // h264 사용 시
        _recordConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    }
    else if (recordFormat == OSXRDP_RECORDFORMAT_RFX) {
        // rfx 사용 시 (ScreenCaptureKit 호환성을 위해 BGRA 캡처 후 상위에서 YUV444 변환)
        _recordConfig.pixelFormat = kCVPixelFormatType_32BGRA;
    }
    else {
        // bitmap 사용 시
        _recordConfig.pixelFormat = kCVPixelFormatType_32BGRA;
    }

    _recordConfig.showsCursor = NO;
    // 구형 os 는 screenrecorderfallback 을 사용하도록 함.
    if (@available(macOS 14.0,*)) {
        _recordConfig.preservesAspectRatio = NO;
    }

    if (framerate <= 0) {
        framerate = 30;
    }
    _recordConfig.minimumFrameInterval = CMTimeMake(100, framerate * 105);
    _deferredQuietMsec = 1000 / framerate + kDeferredQuietMarginMsec;

    // 녹화 큐 설정
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    _recordQue = dispatch_queue_create("osxrdp.record", attr);

    // 녹화 데이터 콜백 (인코딩 한 후 이를 전달하기 위해)
    _recordCb = recordCb;
    _recordCbUserData = userData;

    // 녹화 이벤트 콜백 (갑작스러운 녹화 정지 이벤트를 받기 위해)
    _recordCmdCb = recordCmdCb;
    _recordCmdCbUserData = userData2;

    _displayIdx = displayIdx;
    _displayId = displayId;
    _width = width;
    _height = height;
    _pixelFormat = _recordConfig.pixelFormat;
}

- (BOOL)start {
    if (_recordFilter == nil) {
        NSLog(@"[ScreenRecorderImpl::start] recordFilter is NULL\n");

        return NO;
    }

    if (_recordConfig == nil) {
        NSLog(@"[ScreenRecorderImpl::start] recordConfig is NULL\n");

        return NO;
    }

    if (_recordQue == nil) {
        NSLog(@"[ScreenRecorderImpl::start] recordQue is NULL\n");

        return NO;
    }

    _recordStream = [[SCStream alloc] initWithFilter:_recordFilter configuration:_recordConfig delegate:self];
    if (_recordStream == nil) {
        NSLog(@"[ScreenRecorderImpl::start] could not create stream\n");

        return NO;
    }

    NSError* err = nil;
    if ([_recordStream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_recordQue error:&err] == NO || err != nil) {
        NSLog(@"[ScreenRecorderImpl::start] addStreamOutput failed. %ld\n", (long)err.code);
        _recordStream = nil;

        return NO;
    }

    // Frames can arrive before the completion handler of startCapture runs.
    dispatch_sync(_recordQue, ^{
        self->_running = YES;
        self->_streamStopped = NO;
        self->_snapshotPublished = NO;
        self->_firstFrameCheckCnt = 0;
        self->_startedFrames = 0;
        self->_completeFrames = 0;
        self->_idleFrames = 0;
        self->_blankFrames = 0;
        self->_suspendedFrames = 0;
    });

    NSLog(@"[ScreenRecorderImpl::start] before start record\n");

    // Wait for the result. A stream that failed to start used to be reported as started,
    // which left the client connected to a screen that never gets a single frame.
    __block NSError* startError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [_recordStream startCaptureWithCompletionHandler:^(NSError* _Nullable error) {
        startError = error;
        if (error != nil) {
            NSLog(@"[ScreenRecorderImpl::start] startCapture failed. %ld %@\n", (long)error.code, error.localizedDescription);
        }

        dispatch_semaphore_signal(sema);
    }];

    if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStartCaptureTimeoutSec * NSEC_PER_SEC))) != 0) {
        // Keep going. The stream may still come up, and the first frame check below reports it if it does not.
        NSLog(@"[ScreenRecorderImpl::start] startCapture did not answer in %lld sec\n", (long long)kStartCaptureTimeoutSec);
    }
    else if (startError != nil) {
        dispatch_sync(_recordQue, ^{
            self->_running = NO;
        });

        [_recordStream removeStreamOutput:self type:SCStreamOutputTypeScreen error:nil];
        _recordStream = nil;

        return NO;
    }

    NSLog(@"[ScreenRecorderImpl::start] start record. display %d %dx%d\n", _displayId, _width, _height);

    [self scheduleFirstFrameCheckAfterMsec:kFirstFrameGraceMsec];

    return YES;
}

- (BOOL)stop {
    if (_recordStream == nil) return YES;

    // From here on no frame may reach the callback: the owner releases the shared memory once stop returns,
    // whether the stream really stopped or not.
    __block BOOL alreadyStopped = NO;
    dispatch_sync(_recordQue, ^{
        self->_running = NO;
        alreadyStopped = self->_streamStopped;
        [self dropDeferredSample];
    });

    if (alreadyStopped == NO) {
        // 녹화 정지 요청 후 완전히 종료될때까지 대기
        __block NSError* stopError = nil;
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        [_recordStream stopCaptureWithCompletionHandler:^(NSError* _Nullable err) {
            stopError = err;

            dispatch_semaphore_signal(sema);
        }];

        if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStopCaptureTimeoutSec * NSEC_PER_SEC))) != 0) {
            NSLog(@"[ScreenRecorderImpl::stop] Stop Record did not answer in %lld sec\n", (long long)kStopCaptureTimeoutSec);

            return NO;
        }

        // 아직 녹화가 정지되지 않음.
        if (stopError != nil) {
            NSLog(@"[ScreenRecorderImpl::stop] Stop Record failed. %ld\n", (long)stopError.code);

            return NO;
        }
    }

    NSError* err = nil;
    [_recordStream removeStreamOutput:self type:SCStreamOutputTypeScreen error:&err];
    _recordStream = nil;
    _recordFilter = nil;
    _recordConfig = nil;

    NSLog(@"[ScreenRecorderImpl::stop] Stop Record\n");

    return YES;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || _running == NO) {
        return;
    }

    // dirty area 정보 추출
    NSInteger status = -1;
    int dirtyAreaCnt = GetFrameInfoFromSampleBuffer(sampleBuffer, _dirtyRectBuffer, &status);

    switch (status) {
        case SCFrameStatusComplete:  _completeFrames++;  break;
        case SCFrameStatusStarted:   _startedFrames++;   break;
        case SCFrameStatusIdle:      _idleFrames++;      break;
        case SCFrameStatusBlank:     _blankFrames++;     break;
        case SCFrameStatusSuspended: _suspendedFrames++; break;
        default: break;
    }

    if (dirtyAreaCnt < 0) {
        return;
    }

    [self offerSampleBuffer:sampleBuffer dirtyAreaCnt:dirtyAreaCnt];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    NSLog(@"[ScreenRecorderImpl] stream stopped. display %d error %ld %@\n", _displayId, (long)error.code, error.localizedDescription);

    dispatch_queue_t que = _recordQue;
    if (que != nil) {
        __weak ScreenRecorderImpl* weakSelf = self;
        dispatch_async(que, ^{
            ScreenRecorderImpl* strongSelf = weakSelf;
            if (strongSelf != nil) {
                strongSelf->_running = NO;
                strongSelf->_streamStopped = YES;
                [strongSelf dropDeferredSample];
            }
        });
    }

    // 녹화 정지 요청
    if (_recordCmdCb != NULL) {
        _recordCmdCb(OSXRDP_RECORDCMD_STOPPED, _recordCmdCbUserData);
    }
}

// Hands the image of the sample to the data callback. _recordQue only.
// dirtyAreaCnt: see on_record_data.
// Returns 1 when the frame was taken, 0 when there was no room for it, -1 when the sample has no usable image.
- (int)publishSampleBuffer:(CMSampleBufferRef)sampleBuffer dirtyAreaCnt:(int)dirtyAreaCnt {
    if (_recordCb == NULL) {
        return -1;
    }

    // ImageBuffer 추출 (CVPixelBufferRef와 동일)
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer == NULL) {
        return -1;
    }

    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return -1;
    }

    // 콜백 호출 (osxup 로 화면 데이터 전송)
    int taken = _recordCb(pixelBuffer, _dirtyRectBuffer, dirtyAreaCnt, _recordCbUserData, _displayIdx);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    return taken != 0 ? 1 : 0;
}

// Publishes a new frame. If there is no room for it, the frame is kept and offered again later,
// so the newest picture always reaches the client even when the screen stops changing right after. _recordQue only.
// Returns YES when the sample carried a usable image (taken or kept).
- (BOOL)offerSampleBuffer:(CMSampleBufferRef)sampleBuffer dirtyAreaCnt:(int)dirtyAreaCnt {
    int re = [self publishSampleBuffer:sampleBuffer dirtyAreaCnt:dirtyAreaCnt];
    if (re < 0) {
        return NO;
    }

    _lastOfferNsec = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

    // Either way the frame kept so far is outdated now.
    [self dropDeferredSample];

    if (re == 0) {
        _deferredSample = (CMSampleBufferRef)CFRetain(sampleBuffer);
        [self scheduleDeferredRetryAfterMsec:_deferredQuietMsec];
    }

    return YES;
}

// _recordQue only.
- (void)dropDeferredSample {
    if (_deferredSample != NULL) {
        CFRelease(_deferredSample);
        _deferredSample = NULL;
    }
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

    __weak ScreenRecorderImpl* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMsec * NSEC_PER_MSEC)), que, ^{
        [weakSelf retryDeferredSample];
    });
}

// _recordQue only.
- (void)retryDeferredSample {
    _deferredRetryScheduled = NO;

    if (_running == NO) {
        [self dropDeferredSample];
        return;
    }

    if (_deferredSample == NULL) {
        return;
    }

    // The screen is still changing: a newer frame is about to arrive and takes the place of this one.
    int64_t quietMsec = (int64_t)((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - _lastOfferNsec) / NSEC_PER_MSEC);
    if (quietMsec < _deferredQuietMsec) {
        [self scheduleDeferredRetryAfterMsec:_deferredQuietMsec - quietMsec];
        return;
    }

    int re = [self publishSampleBuffer:_deferredSample dirtyAreaCnt:OSXRDP_DIRTYCNT_RETRY];
    if (re == 0) {
        // still no room
        [self scheduleDeferredRetryAfterMsec:kDeferredRetryMsec];
        return;
    }

    [self dropDeferredSample];
}

- (void)scheduleFirstFrameCheckAfterMsec:(int64_t)delayMsec {
    dispatch_queue_t que = _recordQue;
    if (que == nil) {
        return;
    }

    __weak ScreenRecorderImpl* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMsec * NSEC_PER_MSEC)), que, ^{
        [weakSelf checkFirstFrame];
    });
}

// _recordQue only.
- (void)checkFirstFrame {
    // The screen has changed since the stream started, so the client already has (or is getting) a picture.
    if (_running == NO || _completeFrames > 0 || _snapshotPublished == YES) {
        return;
    }

    _firstFrameCheckCnt++;

    NSLog(@"[ScreenRecorderImpl] display %d has not changed since the stream started (check %d, started=%llu idle=%llu blank=%llu suspended=%llu). publishing a snapshot\n",
          _displayId, _firstFrameCheckCnt,
          (unsigned long long)_startedFrames, (unsigned long long)_idleFrames,
          (unsigned long long)_blankFrames, (unsigned long long)_suspendedFrames);

    // The display is blank or asleep. Ask the owner to wake it up.
    if ((_blankFrames > 0 || _suspendedFrames > 0) && _recordCmdCb != NULL) {
        _recordCmdCb(OSXRDP_RECORDCMD_WAKEDISPLAY, _recordCmdCbUserData);
    }

    [self requestSnapshot];

    if (_firstFrameCheckCnt < kFirstFrameMaxCheckCnt) {
        [self scheduleFirstFrameCheckAfterMsec:kFirstFrameRetryMsec];
    }
}

// _recordQue only.
- (void)requestSnapshot {
    if (@available(macOS 14.0, *)) {
        SCContentFilter* filter = _recordFilter;
        SCStreamConfiguration* config = _recordConfig;
        dispatch_queue_t que = _recordQue;
        if (filter == nil || config == nil || que == nil) {
            return;
        }

        int displayId = _displayId;
        __weak ScreenRecorderImpl* weakSelf = self;
        [SCScreenshotManager captureSampleBufferWithFilter:filter configuration:config completionHandler:^(CMSampleBufferRef _Nullable sampleBuffer, NSError * _Nullable error) {
            if (sampleBuffer == NULL) {
                NSLog(@"[ScreenRecorderImpl] snapshot failed. display %d error %ld %@\n", displayId, (long)error.code, error.localizedDescription);
                return;
            }

            // Blocks do not retain CoreFoundation objects.
            CFRetain(sampleBuffer);
            dispatch_async(que, ^{
                [weakSelf publishSnapshot:sampleBuffer];
                CFRelease(sampleBuffer);
            });
        }];
    }
}

// _recordQue only.
- (void)publishSnapshot:(CMSampleBufferRef)sampleBuffer {
    // A regular frame made it in the meantime.
    if (_running == NO || _completeFrames > 0 || _snapshotPublished == YES) {
        return;
    }

    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer == NULL) {
        NSLog(@"[ScreenRecorderImpl] snapshot has no image. display %d\n", _displayId);
        return;
    }

    // The consumer only understands the layout the stream was configured with.
    if (CVPixelBufferGetPixelFormatType(pixelBuffer) != _pixelFormat ||
        (int)CVPixelBufferGetWidth(pixelBuffer) != _width ||
        (int)CVPixelBufferGetHeight(pixelBuffer) != _height) {
        NSLog(@"[ScreenRecorderImpl] snapshot layout mismatch. display %d %dx%d format %u\n",
              _displayId, (int)CVPixelBufferGetWidth(pixelBuffer), (int)CVPixelBufferGetHeight(pixelBuffer),
              (unsigned int)CVPixelBufferGetPixelFormatType(pixelBuffer));
        return;
    }

    if ([self offerSampleBuffer:sampleBuffer dirtyAreaCnt:0] == YES) {
        _snapshotPublished = YES;
        NSLog(@"[ScreenRecorderImpl] snapshot published. display %d\n", _displayId);
    }
}

// 디스플레이 id 를 사용하여 ScreenCaptureKit 디스플레이 조회
- (SCDisplay*)getDisplayFromDisplayId:(int)displayId {
    for (int attempt = 0; attempt < kDisplayLookupRetryCnt; attempt++) {
        __block SCDisplay* found = nil;
        __block NSError* lookupError = nil;

        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
            lookupError = error;

            for (SCDisplay* item in content.displays) {
                if (item.displayID == (CGDirectDisplayID)displayId) {
                    found = item;
                    break;
                }
            }
            dispatch_semaphore_signal(sema);
        }];

        if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShareableContentTimeoutSec * NSEC_PER_SEC))) != 0) {
            NSLog(@"[ScreenRecorderImpl] shareable content did not answer in %lld sec. display %d\n", (long long)kShareableContentTimeoutSec, displayId);
            return nil;
        }

        if (found != nil) {
            return found;
        }

        if (lookupError != nil) {
            // Usually a missing or stale Screen Recording permission.
            NSLog(@"[ScreenRecorderImpl] could not get shareable content. display %d error %ld %@\n", displayId, (long)lookupError.code, lookupError.localizedDescription);
            return nil;
        }

        usleep(kDisplayLookupRetryIntervalUsec);
    }

    NSLog(@"[ScreenRecorderImpl] display %d is not in the shareable content\n", displayId);

    return nil;
}

@end
