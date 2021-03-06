/// Copyright 2015 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#import "SNTCommandSyncEventUpload.h"

#include "SNTLogging.h"

#import "SNTCertificate.h"
#import "SNTCommandSyncConstants.h"
#import "SNTCommandSyncStatus.h"
#import "SNTStoredEvent.h"
#import "SNTXPCConnection.h"
#import "SNTXPCControlInterface.h"

@implementation SNTCommandSyncEventUpload

+ (void)performSyncInSession:(NSURLSession *)session
                    progress:(SNTCommandSyncStatus *)progress
                  daemonConn:(SNTXPCConnection *)daemonConn
           completionHandler:(void (^)(BOOL success))handler {
  NSURL *url = [NSURL URLWithString:[kURLEventUpload stringByAppendingString:progress.machineID]
                      relativeToURL:progress.syncBaseURL];

  [[daemonConn remoteObjectProxy] databaseEventsPending:^(NSArray *events) {
      if ([events count] == 0) {
        handler(YES);
      } else {
        [self uploadEventsFromArray:events
                              toURL:url
                          inSession:session
                          batchSize:progress.eventBatchSize
                         daemonConn:daemonConn
                  completionHandler:handler];
      }
  }];
}

+ (void)uploadSingleEventWithSHA256:(NSString *)SHA256
                            session:(NSURLSession *)session
                           progress:(SNTCommandSyncStatus *)progress
                         daemonConn:(SNTXPCConnection *)daemonConn
                  completionHandler:(void (^)(BOOL success))handler {
  NSURL *url = [NSURL URLWithString:[kURLEventUpload stringByAppendingString:progress.machineID]
                      relativeToURL:progress.syncBaseURL];
  [[daemonConn remoteObjectProxy] databaseEventForSHA256:SHA256 withReply:^(SNTStoredEvent *event) {
      if (!event) {
        handler(YES);
        return;
      }

      [self uploadEventsFromArray:@[ event ]
                            toURL:url
                        inSession:session
                        batchSize:1
                       daemonConn:daemonConn
                completionHandler:handler];
  }];
}

+ (void)uploadEventsFromArray:(NSArray *)events
                        toURL:(NSURL *)url
                    inSession:(NSURLSession *)session
                    batchSize:(int32_t)batchSize
                   daemonConn:(SNTXPCConnection *)daemonConn
            completionHandler:(void (^)(BOOL success))handler {
  NSMutableArray *uploadEvents = [[NSMutableArray alloc] init];

  NSMutableArray *eventIds = [NSMutableArray arrayWithCapacity:events.count];
  for (SNTStoredEvent *event in events) {
    [uploadEvents addObject:[self dictionaryForEvent:event]];
    [eventIds addObject:event.idx];

    if (eventIds.count >= batchSize) break;
  }

  NSDictionary *uploadReq = @{ kEvents: uploadEvents };

  NSData *requestBody;
  @try {
    requestBody = [NSJSONSerialization dataWithJSONObject:uploadReq options:0 error:nil];
  } @catch (NSException *exception) {
    LOGE(@"Failed to parse event(s) into JSON");
    LOGD(@"Parsing error: %@", [exception reason]);
  }

  NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:url];
  [req setHTTPMethod:@"POST"];
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [req setHTTPBody:requestBody];

  [[session dataTaskWithRequest:req completionHandler:^(NSData *data,
                                                        NSURLResponse *response,
                                                        NSError *error) {
      if ([(NSHTTPURLResponse *)response statusCode] != 200) {
        LOGD(@"HTTP Response Code: %d", [(NSHTTPURLResponse *)response statusCode]);
        handler(NO);
      } else {
        LOGI(@"Uploaded %d events", eventIds.count);

        [[daemonConn remoteObjectProxy] databaseRemoveEventsWithIDs:eventIds];

        NSArray *nextEvents = [events subarrayWithRange:NSMakeRange(eventIds.count,
                                                                    events.count - eventIds.count)];
        if (nextEvents.count == 0) {
          handler(YES);
        } else {
          [self uploadEventsFromArray:nextEvents
                                toURL:url
                            inSession:session
                            batchSize:batchSize
                           daemonConn:daemonConn
                    completionHandler:handler];
        }
      }
  }] resume];
}

+ (NSDictionary *)dictionaryForEvent:(SNTStoredEvent *)event {
#define ADDKEY(dict, key, value) if (value) dict[key] = value
  NSMutableDictionary *newEvent = [NSMutableDictionary dictionary];

  ADDKEY(newEvent, kFileSHA256, event.fileSHA256);
  ADDKEY(newEvent, kFilePath, [event.filePath stringByDeletingLastPathComponent]);
  ADDKEY(newEvent, kFileName, [event.filePath lastPathComponent]);
  ADDKEY(newEvent, kExecutingUser, event.executingUser);
  ADDKEY(newEvent, kExecutionTime, @([event.occurrenceDate timeIntervalSince1970]));
  ADDKEY(newEvent, kDecision, @(event.decision));
  ADDKEY(newEvent, kLoggedInUsers, event.loggedInUsers);
  ADDKEY(newEvent, kCurrentSessions, event.currentSessions);

  ADDKEY(newEvent, kFileBundleID, event.fileBundleID);
  ADDKEY(newEvent, kFileBundleName, event.fileBundleName);
  ADDKEY(newEvent, kFileBundleVersion, event.fileBundleVersion);
  ADDKEY(newEvent, kFileBundleShortVersionString, event.fileBundleVersionString);

  ADDKEY(newEvent, kPID, event.pid);
  ADDKEY(newEvent, kPPID, event.ppid);

  NSMutableArray *signingChain = [NSMutableArray arrayWithCapacity:event.signingChain.count];
  for (int i = 0; i < event.signingChain.count; i++) {
    SNTCertificate *cert = [event.signingChain objectAtIndex:i];

    NSMutableDictionary *certDict = [NSMutableDictionary dictionary];
    ADDKEY(certDict, kCertSHA256, cert.SHA256);
    ADDKEY(certDict, kCertCN, cert.commonName);
    ADDKEY(certDict, kCertOrg, cert.orgName);
    ADDKEY(certDict, kCertOU, cert.orgUnit);
    ADDKEY(certDict, kCertValidFrom, @([cert.validFrom timeIntervalSince1970]));
    ADDKEY(certDict, kCertValidUntil, @([cert.validUntil timeIntervalSince1970]));

    [signingChain addObject:certDict];
  }
  newEvent[kSigningChain] = signingChain;

  return newEvent;
#undef ADDKEY
}

@end
