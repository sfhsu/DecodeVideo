//
//  PlayViewController.m
//  DecodeVideo
//
//  Created by macro macro on 2018/8/1.
//  Copyright © 2018年 macro macro. All rights reserved.
//
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersrc.h>
#include <libavfilter/buffersink.h>
#include <libavutil/opt.h>
};
#import <CoreImage/CoreImage.h>
#import "PlayViewController.h"
#import "PlayESView.h"
@interface PlayViewController ()
@property (weak) IBOutlet NSSlider *slider;
@property (weak) IBOutlet NSTextField *totalTimeLabel;
@property (weak) IBOutlet NSTextField *label;
@property (weak) IBOutlet NSImageView *imageView;
@end

@implementation PlayViewController{
    AVFormatContext * pFormatCtx;
    AVCodecContext * pCodecCtx;
    AVCodec * pCodec;
    NSInteger videoIndex;

    AVFilterContext * buffer_ctx;
    AVFilterContext * bufferSink_ctx;

    CVDisplayLinkRef displayLink;

    double fps;

    NSTimer * timer;

    NSInteger videoDuration;

    CVPixelBufferPoolRef pixelBufferPool;

    CIContext * context;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do view setup here.
    videoIndex = NSNotFound;
    context = [CIContext contextWithOptions:nil];
    [self initDecoder];  //初始化解码器
    [self initFilters];  //初始化过滤器

    self.view.frame = NSRectFromCGRect(CGRectMake(self.view.frame.origin.x, self.view.frame.origin.y, pCodecCtx->width, pCodecCtx->height));

    timer = [NSTimer timerWithTimeInterval:1/fps repeats:YES block:^(NSTimer * _Nonnull timer) { //根据视频的fps解码渲染视频
        [self decodeVideo];  //解码视频并渲染
        [self.view setNeedsLayout:YES];  //刷新界面防止画面撕裂
    }];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSEventTrackingRunLoopMode]; //在改变尺寸时保证计时器能调用
}

- (void)initDecoder {
    //av_register_all(); FFmpeg 4.0废弃

    NSString * videoPath = [[NSBundle mainBundle] pathForResource:@"1" ofType:@"mp4"];
    pFormatCtx = avformat_alloc_context();

    if ((avformat_open_input(&pFormatCtx, videoPath.UTF8String, NULL, NULL)) != 0) {
        NSLog(@"Could not open input stream");
        return;
    }

    if ((avformat_find_stream_info(pFormatCtx, NULL)) < 0) {
        NSLog(@"Could not find stream information");
        return;
    }

    for (NSInteger i = 0; i < pFormatCtx->nb_streams; i++) {
        if (pFormatCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            videoIndex = i;  //视频流的索引
            videoDuration = pFormatCtx->streams[i]->duration * av_q2d(pFormatCtx->streams[i]->time_base); //计算视频时长
            _totalTimeLabel.stringValue = [NSString stringWithFormat:@"%.2ld:%.2ld", videoDuration/60, videoDuration%60];
            if (pFormatCtx->streams[i]->avg_frame_rate.den && pFormatCtx->streams[i]->avg_frame_rate.num) {
                fps = av_q2d(pFormatCtx->streams[i]->avg_frame_rate);  //计算视频fps
            } else {
                fps = 30;
            }
            break;
        }
    }

    if (videoIndex == NSNotFound) {
        NSLog(@"Did not find a video stream");
        return;
    }

    // FFmpeg 3.1 以上AVStream::codec被替换为AVStream::codecpar
    pCodec = avcodec_find_decoder(pFormatCtx->streams[videoIndex]->codecpar->codec_id);
    pCodecCtx = avcodec_alloc_context3(pCodec);
    avcodec_parameters_to_context(pCodecCtx, pFormatCtx->streams[videoIndex]->codecpar);

    if (pCodec == NULL) {
        NSLog(@"Could not open codec");
        return;
    }

    if (avcodec_open2(pCodecCtx, pCodec, NULL) < 0) {
        NSLog(@"Could not open codec");
        return;
    }

    av_dump_format(pFormatCtx, 0, videoPath.UTF8String, 0);
}

- (void)initFilters {

//    avfilter_register_all();  //FFmpeg 4.0废弃

    char args[512];

    AVFilterInOut * inputs = avfilter_inout_alloc();
    AVFilterInOut * outputs = avfilter_inout_alloc();
    AVFilterGraph * filterGraph = avfilter_graph_alloc();

    const AVFilter * buffer = avfilter_get_by_name("buffer");
    const AVFilter * bufferSink = avfilter_get_by_name("buffersink");
    if (!buffer || !bufferSink) {
        NSLog(@"filter not found");
        return;
    }
    AVRational time_base = pFormatCtx->streams[videoIndex]->time_base;
    //视频的描述字符串，这些属性都是必须的否则会创建失败
    snprintf(args, sizeof(args), "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d", pCodecCtx->width,pCodecCtx->height,pCodecCtx->pix_fmt,
             time_base.num, time_base.den,pCodecCtx->sample_aspect_ratio.num,pCodecCtx->sample_aspect_ratio.den);
    NSInteger ret = avfilter_graph_create_filter(&buffer_ctx, buffer, "in", args, NULL, filterGraph);
    if (ret < 0) {
        NSLog(@"can not create buffer source");
        return;
    }
    ret = avfilter_graph_create_filter(&bufferSink_ctx, bufferSink, "out", NULL, NULL, filterGraph);
    if (ret < 0) {
        NSLog(@"can not create buffer sink");
        return;
    }
    enum AVPixelFormat format[] = {AV_PIX_FMT_RGB24};  //想要转换的格式
    ret = av_opt_set_bin(bufferSink_ctx, "pix_fmts", (uint8_t *)&format, sizeof(AV_PIX_FMT_RGB24), AV_OPT_SEARCH_CHILDREN);
    if (ret < 0) {
        NSLog(@"set bin error");
        return;
    }

    outputs->name = av_strdup("in");
    outputs->filter_ctx = buffer_ctx;
    outputs->pad_idx = 0;
    outputs->next = NULL;

    inputs->name = av_strdup("out");
    inputs->filter_ctx = bufferSink_ctx;
    inputs->pad_idx = 0;
    inputs->next = NULL;

    ret = avfilter_graph_parse_ptr(filterGraph, "null", &inputs, &outputs, NULL);  //只转换格式filter名称输入null
    if (ret < 0) {
        NSLog(@"parse error");
        return;
    }

    ret = avfilter_graph_config(filterGraph, NULL);
    if (ret < 0) {
        NSLog(@"config error");
        return;
    }

    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
}

- (void)decodeVideo {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{  //在全局队列中解码
        AVPacket * packet = av_packet_alloc();
        if (av_read_frame(self->pFormatCtx, packet) >= 0) {
            if (packet->stream_index == self->videoIndex) {  //解码视频流
                //FFmpeg 3.0之后avcodec_send_packet和avcodec_receive_frame成对出现用于解码，包括音频和视频的解码，avcodec_decode_video2和avcodec_decode_audio4被废弃
                NSInteger ret = avcodec_send_packet(self->pCodecCtx, packet);
                if (ret < 0) {
                    NSLog(@"send packet error");
                    av_packet_free(&packet);
                    return;
                }
                AVFrame * frame = av_frame_alloc();
                ret = avcodec_receive_frame(self->pCodecCtx, frame);
                if (ret < 0) {
                    NSLog(@"receive frame error");
                    av_frame_free(&frame);
                    return;
                }
                 //frame中data存放解码出的yuv数据，data[0]中是y数据，data[1]中是u数据，data[2]中是v数据，linesize对应的数据长度
                float time = packet->pts * av_q2d(self->pFormatCtx->streams[self->videoIndex]->time_base);  //计算当前帧时间
                av_packet_free(&packet);

                CVReturn theError;
                if (!self->pixelBufferPool){  //创建pixelBuffer缓存池，从缓存池中创建pixelBuffer以便复用
                    NSMutableDictionary* attributes = [NSMutableDictionary dictionary];
                    [attributes setObject:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] forKey:(NSString*)kCVPixelBufferPixelFormatTypeKey];
                    [attributes setObject:[NSNumber numberWithInt:frame->width] forKey: (NSString*)kCVPixelBufferWidthKey];
                    [attributes setObject:[NSNumber numberWithInt:frame->height] forKey: (NSString*)kCVPixelBufferHeightKey];
                    [attributes setObject:@(frame->linesize[0]) forKey:(NSString*)kCVPixelBufferBytesPerRowAlignmentKey];
                    [attributes setObject:[NSDictionary dictionary] forKey:(NSString*)kCVPixelBufferIOSurfacePropertiesKey];
                    theError = CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef) attributes, &self->pixelBufferPool);
                    if (theError != kCVReturnSuccess){
                        NSLog(@"CVPixelBufferPoolCreate Failed");
                    }
                }

                CVPixelBufferRef pixelBuffer = nil;
                theError = CVPixelBufferPoolCreatePixelBuffer(NULL, self->pixelBufferPool, &pixelBuffer);
                if(theError != kCVReturnSuccess){
                    NSLog(@"CVPixelBufferPoolCreatePixelBuffer Failed");
                }

                theError = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
                if (theError != kCVReturnSuccess) {
                    NSLog(@"lock error");
                }
                /*
                 PixelBuffer中Y数据存放在Plane0中，UV数据存放在Plane1中，数据格式如下
                 frame->data[0]  .........   YYYYYYYYY
                 frame->data[1]  .........   UUUUUUUU
                 frame->data[2]  .........   VVVVVVVVV
                 PixelBuffer->Plane0 .......  YYYYYYYY
                 PixelBuffer->Plane1 .......  UVUVUVUVUV
                 所以需要把Y数据拷贝到Plane0上，把U和V数据交叉拷到Plane1上
                 */
                size_t bytePerRowY = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
                size_t bytesPerRowUV = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
                //获取Plane0的起始地址
                void* base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
                memcpy(base, frame->data[0], bytePerRowY * frame->height);
                //获取Plane1的起始地址
                base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
                uint32_t size = frame->linesize[1] * frame->height / 2;
                //把UV数据交叉存储到dstData然后拷贝到Plane1上
                uint8_t* dstData = new uint8_t[2 * size];
                uint8_t * firstData = new uint8_t[size];
                memcpy(firstData, frame->data[1], size);
                uint8_t * secondData  = new uint8_t[size];
                memcpy(secondData, frame->data[2], size);
                for (int i = 0; i < 2 * size; i++){
                    if (i % 2 == 0){
                        dstData[i] = firstData[i/2];
                    }else {
                        dstData[i] = secondData[i/2];
                    }
                }
                memcpy(base, dstData, bytesPerRowUV * frame->height/2);
                CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                av_frame_free(&frame);
                free(dstData);
                free(firstData);
                free(secondData);

                
//                CIImage *coreImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
//                CGImageRef videoImage = [self->context createCGImage:coreImage
//                                                                   fromRect:CGRectMake(0, 0, self->pCodecCtx->width, self->pCodecCtx->height)];
//                NSImage * image = [[NSImage alloc] initWithCGImage:videoImage size:NSSizeFromCGSize(CGSizeMake(self->pCodecCtx->width, self->pCodecCtx->height))];
//                CVPixelBufferRelease(pixelBuffer);
//                CGImageRelease(videoImage);

                dispatch_async(dispatch_get_main_queue(), ^{
                    self.label.stringValue = [NSString stringWithFormat:@"%.2d:%.2d", (int)time/60, (int)time%60];
//                    self.imageView.image = image;
                    PlayESView * esView = (PlayESView *)self.view;
                    [esView renderWithPixelBuffer:pixelBuffer];
                    self.slider.floatValue = time / (float)self->videoDuration;
                });
            }
        } else {
            avcodec_free_context(&self->pCodecCtx);
            avformat_close_input(&self->pFormatCtx);
            avformat_free_context(self->pFormatCtx);
            [self->timer invalidate];
        }
    });
}

@end
