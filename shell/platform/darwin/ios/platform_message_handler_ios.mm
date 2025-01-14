// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "flutter/shell/platform/darwin/ios/platform_message_handler_ios.h"

#import "flutter/fml/trace_event.h"
#import "flutter/lib/ui/window/platform_message.h"
#import "flutter/shell/platform/darwin/common/buffer_conversions.h"
#import "flutter/shell/platform/darwin/common/framework/Headers/FlutterBinaryMessenger.h"

static uint64_t platform_message_counter = 1;

@interface FLTSerialTaskQueue : NSObject <FlutterTaskQueue>
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation FLTSerialTaskQueue
- (instancetype)init {
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create("FLTSerialTaskQueue", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)dealloc {
  dispatch_release(_queue);
  [super dealloc];
}

- (void)dispatch:(dispatch_block_t)block {
  dispatch_async(self.queue, block);
}
@end

namespace flutter {

NSObject<FlutterTaskQueue>* PlatformMessageHandlerIos::MakeBackgroundTaskQueue() {
  return [[[FLTSerialTaskQueue alloc] init] autorelease];
}

PlatformMessageHandlerIos::PlatformMessageHandlerIos(
    fml::RefPtr<fml::TaskRunner> platform_task_runner)
    : platform_task_runner_(std::move(platform_task_runner)) {}

void PlatformMessageHandlerIos::HandlePlatformMessage(std::unique_ptr<PlatformMessage> message) {
  // This can be called from any isolate's thread.
  fml::RefPtr<flutter::PlatformMessageResponse> completer = message->response();
  HandlerInfo handler_info;
  {
    // TODO(gaaclarke): This mutex is a bottleneck for multiple isolates sending
    // messages at the same time. This could be potentially changed to a
    // read-write lock.
    std::lock_guard lock(message_handlers_mutex_);
    auto it = message_handlers_.find(message->channel());
    if (it != message_handlers_.end()) {
      handler_info = it->second;
    }
  }
  if (handler_info.handler) {
    FlutterBinaryMessageHandler handler = handler_info.handler;
    NSData* data = nil;
    if (message->hasData()) {
      data = ConvertMappingToNSData(message->releaseData());
    }

    uint64_t platform_message_id = platform_message_counter++;
    TRACE_EVENT_ASYNC_BEGIN1("flutter", "PlatformChannel ScheduleHandler", platform_message_id,
                             "channel", message->channel().c_str());
    dispatch_block_t run_handler = ^{
      handler(data, ^(NSData* reply) {
        TRACE_EVENT_ASYNC_END0("flutter", "PlatformChannel ScheduleHandler", platform_message_id);
        // Called from any thread.
        if (completer) {
          if (reply) {
            completer->Complete(ConvertNSDataToMappingPtr(reply));
          } else {
            completer->CompleteEmpty();
          }
        }
      });
    };

    if (handler_info.task_queue.get()) {
      [handler_info.task_queue.get() dispatch:run_handler];
    } else {
      dispatch_async(dispatch_get_main_queue(), run_handler);
    }
  } else {
    if (completer) {
      completer->CompleteEmpty();
    }
  }
}

bool PlatformMessageHandlerIos::DoesHandlePlatformMessageOnPlatformThread() const {
  return false;
}

void PlatformMessageHandlerIos::InvokePlatformMessageResponseCallback(
    int response_id,
    std::unique_ptr<fml::Mapping> mapping) {
  // Called from any thread.
  // TODO(gaaclarke): This vestigal from the Android implementation, find a way
  // to migrate this to PlatformMessageHandlerAndroid.
}

void PlatformMessageHandlerIos::InvokePlatformMessageEmptyResponseCallback(int response_id) {
  // Called from any thread.
  // TODO(gaaclarke): This vestigal from the Android implementation, find a way
  // to migrate this to PlatformMessageHandlerAndroid.
}

void PlatformMessageHandlerIos::SetMessageHandler(const std::string& channel,
                                                  FlutterBinaryMessageHandler handler,
                                                  NSObject<FlutterTaskQueue>* task_queue) {
  FML_CHECK(platform_task_runner_->RunsTasksOnCurrentThread());
  /// TODO(gaaclarke): This should be migrated to a lockfree datastructure.
  std::lock_guard lock(message_handlers_mutex_);
  message_handlers_.erase(channel);
  if (handler) {
    message_handlers_[channel] = {
        .task_queue = fml::scoped_nsprotocol([task_queue retain]),
        .handler =
            fml::ScopedBlock<FlutterBinaryMessageHandler>{handler, fml::OwnershipPolicy::Retain},
    };
  }
}
}  // namespace flutter
