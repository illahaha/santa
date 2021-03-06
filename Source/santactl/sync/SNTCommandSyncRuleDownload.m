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

#import "SNTCommandSyncRuleDownload.h"

#import "SNTCommandSyncConstants.h"
#import "SNTCommandSyncStatus.h"
#import "SNTRule.h"
#import "SNTXPCConnection.h"
#import "SNTXPCControlInterface.h"

#include "SNTLogging.h"

@implementation SNTCommandSyncRuleDownload

+ (void)performSyncInSession:(NSURLSession *)session
                    progress:(SNTCommandSyncStatus *)progress
                  daemonConn:(SNTXPCConnection *)daemonConn
           completionHandler:(void (^)(BOOL success))handler {
  NSURL *url = [NSURL URLWithString:[kURLRuleDownload stringByAppendingString:progress.machineID]
                      relativeToURL:progress.syncBaseURL];
  [self ruleDownloadWithCursor:nil
                           url:url
                       session:session
                      progress:progress
                    daemonConn:daemonConn
             completionHandler:handler];
}

+ (void)ruleDownloadWithCursor:(NSString *)cursor
                           url:(NSURL *)url
                       session:(NSURLSession *)session
                      progress:(SNTCommandSyncStatus *)progress
                    daemonConn:(SNTXPCConnection *)daemonConn
             completionHandler:(void (^)(BOOL success))handler {

  NSDictionary *requestDict = (cursor ? @{ kCursor: cursor } : @{});

  if (!progress.downloadedRules) {
    progress.downloadedRules = [NSMutableArray array];
  }

  NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:url];
  [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:requestDict
                                                   options:0
                                                     error:nil]];
  [req setHTTPMethod:@"POST"];
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [[session dataTaskWithRequest:req completionHandler:^(NSData *data,
                                                        NSURLResponse *response,
                                                        NSError *error) {
      if ([(NSHTTPURLResponse *)response statusCode] != 200) {
        LOGD(@"HTTP Response Code: %d", [(NSHTTPURLResponse *)response statusCode]);
        handler(NO);
      } else {
        NSDictionary *resp = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!resp) {
          LOGE(@"Failed to decode server's response");
          handler(NO);
        }

        NSArray *receivedRules = resp[kRules];
        for (NSDictionary *rule in receivedRules) {
          if (![rule isKindOfClass:[NSDictionary class]]) continue;

          SNTRule *newRule = [[SNTRule alloc] init];
          newRule.shasum = rule[kRuleSHA256];

          if ([rule[kRulePolicy] isEqual:kRulePolicyWhitelist]) {
            newRule.state = RULESTATE_WHITELIST;
          } else if ([rule[kRulePolicy] isEqual:kRulePolicyBlacklist]) {
            newRule.state = RULESTATE_BLACKLIST;
          } else if ([rule[kRulePolicy] isEqual:kRulePolicySilentBlacklist]) {
            newRule.state = RULESTATE_SILENT_BLACKLIST;
          } else if ([rule[kRulePolicy] isEqual:kRulePolicyRemove]) {
            newRule.state = RULESTATE_REMOVE;
          } else {
            continue;
          }

          if ([rule[kRuleType] isEqual:kRuleTypeBinary]) {
            newRule.type = RULETYPE_BINARY;
          } else if ([rule[kRuleType] isEqual:kRuleTypeCertificate]) {
            newRule.type = RULETYPE_CERT;
          } else {
            continue;
          }

          NSString *customMsg = rule[kRuleCustomMsg];
          if (customMsg) {
            newRule.customMsg = customMsg;
          }

          [progress.downloadedRules addObject:newRule];
        }

        if (resp[kCursor]) {
          [self ruleDownloadWithCursor:resp[kCursor]
                                   url:url
                               session:session
                              progress:progress
                            daemonConn:daemonConn
                     completionHandler:handler];
        } else {
          [[daemonConn remoteObjectProxy] databaseRuleAddRules:progress.downloadedRules withReply:^{
              if (progress.downloadedRules.count) {
                LOGI(@"Added %d rule(s)", progress.downloadedRules.count);
              }
              handler(YES);
          }];
        }
      }
  }] resume];
}

@end
