

#include "AQPlayer.h"

void AQPlayer::AQBufferCallback(void *                    inUserData,
                                AudioQueueRef            inAQ,
                                AudioQueueBufferRef        inCompleteAQBuffer) 
{
    AQPlayer *THIS = (AQPlayer *)inUserData;

    if (THIS->mIsDone) return;

    UInt32 numBytes;
    UInt32 nPackets = THIS->GetNumPacketsToRead();
    OSStatus result = AudioFileReadPackets(THIS->GetAudioFileID(), false, &numBytes, inCompleteAQBuffer->mPacketDescriptions, THIS->GetCurrentPacket(), &nPackets, 
                                           inCompleteAQBuffer->mAudioData);
    if (result)
        printf("AudioFileReadPackets failed: %ld", result);
    if (nPackets > 0) {
        inCompleteAQBuffer->mAudioDataByteSize = numBytes;        
        inCompleteAQBuffer->mPacketDescriptionCount = nPackets;        
        AudioQueueEnqueueBuffer(inAQ, inCompleteAQBuffer, 0, NULL);
        THIS->mCurrentPacket = (THIS->GetCurrentPacket() + nPackets);
    } 
    
    else 
    {
        if (THIS->IsLooping())
        {
            THIS->mCurrentPacket = 0;
            AQBufferCallback(inUserData, inAQ, inCompleteAQBuffer);
        }
        else
        {
            // stop
            THIS->mIsDone = true;
            AudioQueueStop(inAQ, false);
        }
    }
}

void AQPlayer::isRunningProc (  void *              inUserData,
                                AudioQueueRef           inAQ,
                                AudioQueuePropertyID    inID)
{
    AQPlayer *THIS = (AQPlayer *)inUserData;
    UInt32 size = sizeof(THIS->mIsRunning);
    OSStatus result = AudioQueueGetProperty (inAQ, kAudioQueueProperty_IsRunning, &THIS->mIsRunning, &size);
    
    if ((result == noErr) && (!THIS->mIsRunning)) {
        NSString *file = (NSString *)THIS->GetFilePath();
        NSString *name = @"";
        if (file) {
            name = [[[file lastPathComponent] componentsSeparatedByString:@"."] objectAtIndex:0];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:kPlaybackQueueStopped object:[[name copy] autorelease]];
    }
}

void AQPlayer::CalculateBytesForTime (CAStreamBasicDescription & inDesc, UInt32 inMaxPacketSize, Float64 inSeconds, UInt32 *outBufferSize, UInt32 *outNumPackets)
{
    // we only use time here as a guideline
    // we're really trying to get somewhere between 16K and 64K buffers, but not allocate too much if we don't need it
    static const int maxBufferSize = 0x10000; // limit size to 64K
    static const int minBufferSize = 0x4000; // limit size to 16K
    
    if (inDesc.mFramesPerPacket) {
        Float64 numPacketsForTime = inDesc.mSampleRate / inDesc.mFramesPerPacket * inSeconds;
        *outBufferSize = numPacketsForTime * inMaxPacketSize;
    } else {
        // if frames per packet is zero, then the codec has no predictable packet == time
        // so we can't tailor this (we don't know how many Packets represent a time period
        // we'll just return a default buffer size
        *outBufferSize = maxBufferSize > inMaxPacketSize ? maxBufferSize : inMaxPacketSize;
    }
    
    // we're going to limit our size to our default
    if (*outBufferSize > maxBufferSize && *outBufferSize > inMaxPacketSize)
        *outBufferSize = maxBufferSize;
    else {
        // also make sure we're not too small - we don't want to go the disk for too small chunks
        if (*outBufferSize < minBufferSize)
            *outBufferSize = minBufferSize;
    }
    *outNumPackets = *outBufferSize / inMaxPacketSize;
}

AQPlayer::AQPlayer() :
    mQueue(0),
    mAudioFile(0),
    mFilePath(NULL),
    mIsRunning(false),
    mIsInitialized(false),
    mNumPacketsToRead(0),
    mCurrentPacket(0),
    mIsDone(false),
    mIsLooping(false) { }

AQPlayer::~AQPlayer() 
{
    DisposeQueue(true);
}

NSTimeInterval AQPlayer::CurrentTime()
{
    NSTimeInterval timeInterval = 0.0;
    
    AudioQueueTimelineRef timeLine;
    OSStatus status = AudioQueueCreateTimeline(mQueue, &timeLine);
    if(status == noErr)
    {
        AudioTimeStamp timeStamp;
        AudioQueueGetCurrentTime(mQueue, timeLine, &timeStamp, NULL);
        timeInterval = timeStamp.mSampleTime / mDataFormat.mSampleRate;
//        timeInterval = timeStamp.mSampleTime;
    }
    
    return timeInterval;
}

NSTimeInterval AQPlayer::TotalDuration()
{   
    UInt64 nPackets;
    UInt32 propsize = sizeof(nPackets);
    
    XThrowIfError (AudioFileGetProperty(mAudioFile, kAudioFilePropertyAudioDataPacketCount, &propsize, &nPackets), "kAudioFilePropertyAudioDataPacketCount");
    Float64 fileDuration = (nPackets * mDataFormat.mFramesPerPacket) / mDataFormat.mSampleRate;
    
    return fileDuration;
}

OSStatus AQPlayer::StartQueue(BOOL inResume)
{    
    // if we have a file but no queue, create one now
    if ((mQueue == NULL) && (mFilePath != NULL))
        CreateQueueForFile(mFilePath);
    
    mIsDone = false;
    
    // if we are not resuming, we also should restart the file read index
    if (!inResume)
        mCurrentPacket = 0;    

    // prime the queue with some data before starting
    for (int i = 0; i < kNumberBuffers; ++i) {
        AQBufferCallback (this, mQueue, mBuffers[i]);            
    }
    return AudioQueueStart(mQueue, NULL);
}

OSStatus AQPlayer::StopQueue()
{
    OSStatus result = AudioQueueStop(mQueue, true);
    if (result) printf("ERROR STOPPING QUEUE!\n");

    return result;
}

OSStatus AQPlayer::PauseQueue()
{
    OSStatus result = AudioQueuePause(mQueue);

    return result;
}

bool AQPlayer::CreateQueueForFile(CFStringRef fileName) 
{
    // CFStringRef inFilePath = (CFStringRef)[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.wav", (NSString *)fileName]];
//    CFStringRef inFilePath = (CFStringRef)[[NSBundle mainBundle] pathForResource:(NSString *)fileName ofType:nil];
    if (fileName == nil || fileName == NULL) {
        return false;
    }
    CFStringRef inFilePath = fileName;
    if (![[NSFileManager defaultManager] fileExistsAtPath:(NSString *)inFilePath isDirectory:NO]) {
        return false;
    }
    
    CFURLRef sndFile = NULL; 
    try {
        if (mFilePath == NULL) {
            mIsLooping = false;
            
            sndFile = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, inFilePath, kCFURLPOSIXPathStyle, false);
            if (!sndFile) { printf("can't parse file path\n"); return false; }
            XThrowIfError(AudioFileOpenURL (sndFile, kAudioFileReadPermission, 0/*inFileTypeHint*/, &mAudioFile), "can't open file");
            UInt32 size = sizeof(mDataFormat);
            XThrowIfError(AudioFileGetProperty(mAudioFile, 
                                           kAudioFilePropertyDataFormat, &size, &mDataFormat), "couldn't get file's data format");
            mFilePath = CFStringCreateCopy(kCFAllocatorDefault, inFilePath);
        }
        SetupNewQueue();        
    }
    catch (CAXException e) {
        char buf[256];
        fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
    }
    if (sndFile)
        CFRelease(sndFile);
    return true;
}

void AQPlayer::SetupNewQueue() 
{
    XThrowIfError(AudioQueueNewOutput(&mDataFormat, AQPlayer::AQBufferCallback, this, 
                                        CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &mQueue), "AudioQueueNew failed");
    UInt32 bufferByteSize;        
    // we need to calculate how many packets we read at a time, and how big a buffer we need
    // we base this on the size of the packets in the file and an approximate duration for each buffer
    // first check to see what the max size of a packet is - if it is bigger
    // than our allocation default size, that needs to become larger
    UInt32 maxPacketSize;
    UInt32 size = sizeof(maxPacketSize);
    XThrowIfError(AudioFileGetProperty(mAudioFile, 
                                       kAudioFilePropertyPacketSizeUpperBound, &size, &maxPacketSize), "couldn't get file's max packet size");
    
    // adjust buffer size to represent about a half second of audio based on this format
    CalculateBytesForTime (mDataFormat, maxPacketSize, kBufferDurationSeconds, &bufferByteSize, &mNumPacketsToRead);

        //printf ("Buffer Byte Size: %d, Num Packets to Read: %d\n", (int)bufferByteSize, (int)mNumPacketsToRead);
    
    // (2) If the file has a cookie, we should get it and set it on the AQ
    size = sizeof(UInt32);
    OSStatus result = AudioFileGetPropertyInfo (mAudioFile, kAudioFilePropertyMagicCookieData, &size, NULL);
    
    if (!result && size) {
        char* cookie = new char [size];        
        XThrowIfError (AudioFileGetProperty (mAudioFile, kAudioFilePropertyMagicCookieData, &size, cookie), "get cookie from file");
        XThrowIfError (AudioQueueSetProperty(mQueue, kAudioQueueProperty_MagicCookie, cookie, size), "set cookie on queue");
        delete [] cookie;
    }
    
    // channel layout?
    result = AudioFileGetPropertyInfo(mAudioFile, kAudioFilePropertyChannelLayout, &size, NULL);
    if (result == noErr && size > 0) {
        AudioChannelLayout *acl = (AudioChannelLayout *)malloc(size);
        XThrowIfError(AudioFileGetProperty(mAudioFile, kAudioFilePropertyChannelLayout, &size, acl), "get audio file's channel layout");
        XThrowIfError(AudioQueueSetProperty(mQueue, kAudioQueueProperty_ChannelLayout, acl, size), "set channel layout on queue");
        free(acl);
    }
    
    XThrowIfError(AudioQueueAddPropertyListener(mQueue, kAudioQueueProperty_IsRunning, isRunningProc, this), "adding property listener");
    
    bool isFormatVBR = (mDataFormat.mBytesPerPacket == 0 || mDataFormat.mFramesPerPacket == 0);
    for (int i = 0; i < kNumberBuffers; ++i) {
        XThrowIfError(AudioQueueAllocateBufferWithPacketDescriptions(mQueue, bufferByteSize, (isFormatVBR ? mNumPacketsToRead : 0), &mBuffers[i]), "AudioQueueAllocateBuffer failed");
    }    

    // set the volume of the queue
    XThrowIfError (AudioQueueSetParameter(mQueue, kAudioQueueParam_Volume, 1.0), "set queue volume");// 音量
    
    mIsInitialized = true;
}

void AQPlayer::DisposeQueue(Boolean inDisposeFile)
{
    if (mQueue)
    {
        AudioQueueDispose(mQueue, true);
        mQueue = NULL;
    }
    if (inDisposeFile)
    {
        if (mAudioFile)
        {        
            AudioFileClose(mAudioFile);
            mAudioFile = 0;
        }
        if (mFilePath)
        {
            CFRelease(mFilePath);
            mFilePath = NULL;
        }
    }
    mIsInitialized = false;
}