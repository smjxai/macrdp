//
//  IScreenRecorder.h
//  OSXRDP
//
//  Created by byungho on 4/22/26.
//

#ifndef IScreenRecorderImpl_h
#define IScreenRecorderImpl_h

#import <Foundation/Foundation.h>

// on_record_cmd commands
#define OSXRDP_RECORDCMD_STOPPED        1   // the recorder stopped unexpectedly
#define OSXRDP_RECORDCMD_WAKEDISPLAY    2   // the display is blank / asleep, wake it up

// dirtyRectsCnt
//    > 0 : number of entries in dirtyRects
//      0 : the whole frame must be redrawn
//     -1 : (OSXRDP_DIRTYCNT_RETRY) the same frame is offered again after it was refused
#define OSXRDP_DIRTYCNT_RETRY           (-1)

// Returns 1 when the frame was taken.
// Returns 0 when there was no room for it. The recorder must then keep the frame and offer it again
// (with OSXRDP_DIRTYCNT_RETRY) until it is taken or a newer frame replaces it. Otherwise the last frame
// of a burst of screen changes is lost and the client keeps showing an outdated picture.
typedef int (*on_record_data)(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData, int displayIdx);
typedef void (*on_record_cmd)(int cmd, void* userData);

@protocol IScreenRecorder<NSObject>

@required
- (void)initializeWithDisplayId:(int)displayId
            DisplayIndex:(int)displayIdx
            RecordWidth:(int)width
            RecordHeight:(int)height
            RecordFramerate:(int)framerate
            RecordFormat:(int)recordFormat
            RecordDataCallback:(on_record_data)recordCb
            RecordDataCallbackUserData:(void*)userData
            RecordCmdCallback:(on_record_cmd)recordCmdCb
            RecordCmdCallbackUserData:(void*)userData2;
- (BOOL)start;
- (BOOL)stop;

@end


#endif /* IScreenRecorderImpl_h */
