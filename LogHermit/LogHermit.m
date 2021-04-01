//
//  LogHermit.m
//  LogHermit
//
//  Created by 彭远洋 on 2021/2/5.
//

#import "LogHermit.h"
#import <sys/uio.h>
#import <stdio.h>
#import "fishhook.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import "WXSDKInstance.h"
#import "WXSDKEngine.h"
#import "WXBridgeManager.h"
#import "PDRCore.h"
#import "WeexProtocol.h"

@implementation LogHermit

void rebindFunction(void);

// swift5.x 只需要hook这一个方法即可
static size_t (*orig_fwrite)(const void * __restrict, size_t, size_t, FILE * __restrict);
size_t new_fwrite(const void * __restrict ptr, size_t size, size_t nitems, FILE * __restrict stream) {
    char *str = (char *)ptr;
    __block NSString *s = [NSString stringWithCString:str encoding:NSUTF8StringEncoding];
    [LogHermit logMessage:s];
    return orig_fwrite(ptr, size, nitems, stream);
}

// 这个方法就是NSLog底层调用.. 所以把不hook NSLog了
static ssize_t (*orig_writev)(int a, const struct iovec *, int);
ssize_t new_writev(int a, const struct iovec *v, int v_len) {
    NSMutableString *string = [NSMutableString string];
    for (int i = 0; i < v_len; i++) {
        char *c = (char *)v[i].iov_base;
        [string appendString:[NSString stringWithCString:c encoding:NSUTF8StringEncoding]];
    }
    ssize_t result = orig_writev(a, v, v_len);
    dispatch_async(dispatch_get_main_queue(), ^{
        [LogHermit logMessage:string];
    });
    return result;
}

void rebindFunction(void) {
    rebind_symbols((struct rebinding[1]){{"fwrite", new_fwrite, (void *)&orig_fwrite}}, 1);

    // DDLog 用到了
    rebind_symbols((struct rebinding[1]){{"writev", new_writev, (void *)&orig_writev}}, 1);
}

+ (void)load {
    [LogHermit start];
}

+ (void)start {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        rebindFunction();
    });
}

+(void)logMessage:(NSString *)msg {
    @try {
        [self log:msg];
    } @catch (NSException *exception) {
        // 不进行 Log 输出
    }
}

+ (void)log:(NSString *)msg {
    if (!([msg containsString:@"Sensors"] || ![msg containsString:@"SA"])) {
        return;
    }
    if ([msg containsString:@"<Weex>"]) {
        return;
    }
    WXPerformBlockOnBridgeThread(^{
        PDRCore *core = [PDRCore Instance];
        if ([core respondsToSelector:NSSelectorFromString(@"weexImport")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id<WeexProtocol> weexImport = [core performSelector:NSSelectorFromString(@"weexImport")];
            id top = [[weexImport newWXSDKInstance] instanceJavaScriptContext];
            if ([top respondsToSelector:NSSelectorFromString(@"javaScriptContext")]) {
                JSContext *context =(JSContext *)[top performSelector:NSSelectorFromString(@"javaScriptContext")];
                NSString *js = @"function logMessage(message){ console.log(message)}";
                [context evaluateScript:js];
                JSValue *function = context[@"logMessage"];
                [function callWithArguments:@[msg]];
            }
#pragma clang diagnostic pop
        }
    });
}

WX_EXPORT_METHOD(@selector(testConsoleLog:))
- (void)testConsoleLog:(NSString *)logMessage {
    [LogHermit logMessage:logMessage];
}

@end
