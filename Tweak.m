//
//  DYYYAlbum — 给 DYYY 的下载流程加「保存到相簿」选择
//  纯 ObjC 运行时 hook，不依赖 CydiaSubstrate
//
//  v1.1.0
//  - 相簿归档改为「两段式」：先让 DYYY 的原保存事务照常提交，
//    成功后再开一个独立事务把资产加入相簿。
//    这样即使归档失败也只是少归档，绝不连累保存本身。
//  - 所有 PhotoKit 调用都包 @try/@catch，异常只记日志不外抛。
//  - 增加文件日志（NSTemporaryDirectory()/dyyyalbum.log），方便定位问题。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

#define DDA_LOG(fmt, ...) DDLogInternal(fmt, ##__VA_ARGS__)

static NSString *const kLastAlbumIDKey = @"DYYYAlbum.lastAlbumID";
static NSString *const kLastAlbumNameKey = @"DYYYAlbum.lastAlbumName";
static NSString *const kCollectorKey = @"DYYYAlbum.placeholderCollector";
static NSString *const kAlbumAddKey = @"DYYYAlbum.inAlbumAdd";

// 选好的目标相簿（在下载/保存期间有效）
static NSString *gPendingAlbumID = nil;
static NSString *gPendingAlbumName = nil;
static NSTimeInterval gPendingExpiry = 0;
static BOOL gPickerShowing = NO;
static BOOL gDYYYHooksInstalled = NO;

@interface DYYYAlbum : NSObject
@end

@implementation DYYYAlbum
@end

#pragma mark - 日志

static void DDLogInternal(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[DYYYAlbum] %@", msg);

    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      q = dispatch_queue_create("com.ahao.dyyyalbum.log", DISPATCH_QUEUE_SERIAL);
    });
    NSString *line = [NSString stringWithFormat:@"%@ [DYYYAlbum] %@\n",
                                                [NSDate date], msg];
    dispatch_async(q, ^{
      NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"dyyyalbum.log"];
      NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
      @try {
          if (!fh) {
              [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
              return;
          }
          [fh seekToEndOfFile];
          [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
          [fh closeFile];
      } @catch (__unused NSException *e) {
      }
    });
}

static NSTimeInterval DDNow(void) {
    return [NSDate timeIntervalSinceReferenceDate];
}

#pragma mark - 目标相簿状态

static void DDSetPendingAlbum(NSString *albumID, NSString *albumName) {
    @synchronized([DYYYAlbum class]) {
        gPendingAlbumID = [albumID copy];
        gPendingAlbumName = [albumName copy];
        gPendingExpiry = DDNow() + 900.0; // 一次下载期间有效（大文件留足时间）
    }
    @try {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (albumID.length) {
            [d setObject:albumID forKey:kLastAlbumIDKey];
            [d setObject:(albumName ?: @"") forKey:kLastAlbumNameKey];
        } else {
            [d removeObjectForKey:kLastAlbumIDKey];
            [d removeObjectForKey:kLastAlbumNameKey];
        }
        [d synchronize];
    } @catch (__unused NSException *e) {
    }
}

static NSString *DDPendingAlbumID(void) {
    @synchronized([DYYYAlbum class]) {
        if (DDNow() > gPendingExpiry) {
            gPendingAlbumID = nil;
            gPendingAlbumName = nil;
            return nil;
        }
        return gPendingAlbumID;
    }
}

static void DDRefreshPendingExpiry(void) {
    @synchronized([DYYYAlbum class]) {
        if (gPendingAlbumID.length) {
            gPendingExpiry = DDNow() + 900.0;
        }
    }
}

static NSString *DDLastAlbumID(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kLastAlbumIDKey];
}

#pragma mark - 顶层控制器

static UIViewController *DDTopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) {
                keyWindow = w;
                break;
            }
        }
        if (keyWindow) {
            break;
        }
    }
    if (!keyWindow) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            keyWindow = ((UIWindowScene *)scene).windows.firstObject;
            if (keyWindow) {
                break;
            }
        }
    }
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

#pragma mark - 相簿列表

static NSArray<PHAssetCollection *> *DDFetchUserAlbums(void) {
    NSMutableArray<PHAssetCollection *> *albums = [NSMutableArray array];
    @try {
        PHFetchResult<PHAssetCollection *> *result =
            [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                     subtype:PHAssetCollectionSubtypeAny
                                                     options:nil];
        for (PHAssetCollection *album in result) {
            if (album.localizedTitle.length) {
                [albums addObject:album];
            }
        }
        [albums sortUsingComparator:^NSComparisonResult(PHAssetCollection *a, PHAssetCollection *b) {
          return [a.localizedTitle localizedCompare:b.localizedTitle];
        }];
    } @catch (NSException *e) {
        DDA_LOG(@"读取相簿列表失败: %@", e);
    }
    return albums;
}

#pragma mark - 新建相簿

static void DDCreateAlbum(NSString *title, void (^completion)(PHAssetCollection *album)) {
    __block PHObjectPlaceholder *placeholder = nil;
    @try {
        [[PHPhotoLibrary sharedPhotoLibrary]
            performChanges:^{
              PHAssetCollectionChangeRequest *req =
                  [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:title];
              placeholder = req.placeholderForCreatedAssetCollection;
            }
            completionHandler:^(BOOL success, NSError *error) {
              if (!success || !placeholder.localIdentifier) {
                  DDA_LOG(@"新建相簿失败: %@", error);
                  dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) {
                        completion(nil);
                    }
                  });
                  return;
              }
              PHAssetCollection *album = nil;
              @try {
                  PHFetchResult<PHAssetCollection *> *r =
                      [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[
                          placeholder.localIdentifier
                      ]
                                                                           options:nil];
                  album = r.firstObject;
              } @catch (NSException *e) {
                  DDA_LOG(@"读取新相簿失败: %@", e);
              }
              dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(album);
                }
              });
            }];
    } @catch (NSException *e) {
        DDA_LOG(@"创建相簿异常: %@", e);
        dispatch_async(dispatch_get_main_queue(), ^{
          if (completion) {
              completion(nil);
          }
        });
    }
}

#pragma mark - 相簿选择弹窗

static void DDPresentPicker(void (^proceed)(BOOL shouldDownload));

static void DDShowNewAlbumAlert(void (^proceed)(BOOL)) {
    UIViewController *top = DDTopViewController();
    if (!top) {
        gPickerShowing = NO;
        proceed(YES);
        return;
    }
    gPickerShowing = YES;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建相簿"
                                                                   message:@"输入相簿名称"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
      tf.placeholder = @"相簿名称";
      tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *a) {
                                              gPickerShowing = NO;
                                              dispatch_async(dispatch_get_main_queue(), ^{
                                                DDPresentPicker(proceed);
                                              });
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"创建"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
                                              NSString *name = [weakAlert.textFields.firstObject.text
                                                  stringByTrimmingCharactersInSet:[NSCharacterSet
                                                                                      whitespaceAndNewlineCharacterSet]];
                                              if (!name.length) {
                                                  gPickerShowing = NO;
                                                  proceed(YES);
                                                  return;
                                              }
                                              DDCreateAlbum(name, ^(PHAssetCollection *album) {
                                                if (album) {
                                                    DDSetPendingAlbum(album.localIdentifier,
                                                                      album.localizedTitle ?: name);
                                                }
                                                gPickerShowing = NO;
                                                proceed(YES);
                                              });
                                            }]];
    [top presentViewController:alert animated:YES completion:nil];
}

static void DDShowPickerSheet(void (^proceed)(BOOL)) {
    UIViewController *top = DDTopViewController();
    if (!top) {
        gPickerShowing = NO;
        proceed(YES);
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"保存到相簿"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<PHAssetCollection *> *albums = DDFetchUserAlbums();
    NSString *lastID = DDLastAlbumID();
    NSMutableArray<PHAssetCollection *> *ordered = [NSMutableArray array];
    for (PHAssetCollection *album in albums) {
        if (lastID.length && [album.localIdentifier isEqualToString:lastID]) {
            [ordered insertObject:album atIndex:0];
        } else {
            [ordered addObject:album];
        }
    }

    NSUInteger limit = MIN(ordered.count, (NSUInteger)20);
    for (NSUInteger i = 0; i < limit; i++) {
        PHAssetCollection *album = ordered[i];
        BOOL isLast = lastID.length && [album.localIdentifier isEqualToString:lastID];
        NSString *title = isLast ? [NSString stringWithFormat:@"✓ %@", album.localizedTitle]
                                 : album.localizedTitle;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
                                                  DDSetPendingAlbum(album.localIdentifier,
                                                                    album.localizedTitle);
                                                  gPickerShowing = NO;
                                                  proceed(YES);
                                                }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"最近项目"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                              DDSetPendingAlbum(nil, nil);
                                              gPickerShowing = NO;
                                              proceed(YES);
                                            }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"新建相簿…"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                              dispatch_async(dispatch_get_main_queue(), ^{
                                                DDShowNewAlbumAlert(proceed);
                                              });
                                            }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消下载"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
                                              gPickerShowing = NO;
                                              proceed(NO);
                                            }]];

    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = top.view;
        sheet.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
        sheet.popoverPresentationController.permittedArrowDirections = 0;
    }
    [top presentViewController:sheet animated:YES completion:nil];

    // 弹窗没能正常出现（被别的控制器占用等）时兜底，避免下载永远卡住
    __weak UIAlertController *weakSheet = sheet;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     if (!gPickerShowing) {
                         return;
                     }
                     UIAlertController *s = weakSheet;
                     if (s && (s.isBeingPresented || s.presentingViewController || s.view.window)) {
                         return;
                     }
                     DDA_LOG(@"相簿弹窗未出现，按最近项目继续");
                     gPickerShowing = NO;
                     proceed(YES);
                   });
}

static void DDShowPickerNow(void (^proceed)(BOOL)) {
    PHAuthorizationStatus status =
        [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                                   handler:^(PHAuthorizationStatus newStatus) {
                                                     dispatch_async(dispatch_get_main_queue(), ^{
                                                       if (newStatus == PHAuthorizationStatusDenied ||
                                                           newStatus == PHAuthorizationStatusRestricted) {
                                                           gPickerShowing = NO;
                                                           proceed(YES);
                                                           return;
                                                       }
                                                       DDShowPickerSheet(proceed);
                                                     });
                                                   }];
        return;
    }
    DDShowPickerSheet(proceed);
}

static void DDPresentPicker(void (^proceed)(BOOL)) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (gPickerShowing) {
          // 已有弹窗时直接沿用当前选择，避免连续下载时堆叠弹窗
          proceed(YES);
          return;
      }
      gPickerShowing = YES;

      // 抖音长按面板通常在调用下载后才收起来，稍等一下再弹，避免被面板盖住或一起关掉
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
                       if (!gPickerShowing) {
                           return;
                       }
                       DDShowPickerNow(proceed);
                     });
    });
}

#pragma mark - 资产收集（事务内只记录，不做别的）

static void DDCollectRequest(id request) {
    if (!request) {
        return;
    }
    NSMutableArray *collector = [[NSThread currentThread] threadDictionary][kCollectorKey];
    if (!collector) {
        return;
    }
    @try {
        if (![request respondsToSelector:@selector(placeholderForCreatedAsset)]) {
            return;
        }
        PHObjectPlaceholder *placeholder = [request placeholderForCreatedAsset];
        if (placeholder) {
            [collector addObject:placeholder];
        }
    } @catch (NSException *e) {
        DDA_LOG(@"收集资产失败: %@", e);
    }
}

#pragma mark - 提交后：独立事务加入相簿

static void DDAddAssetsToAlbum(NSString *albumID, NSString *albumName, NSArray *placeholders) {
    if (!albumID.length || placeholders.count == 0) {
        return;
    }

    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (id ph in placeholders) {
        @try {
            NSString *lid = [ph respondsToSelector:@selector(localIdentifier)] ? [ph localIdentifier] : nil;
            if (lid.length) {
                [ids addObject:lid];
            }
        } @catch (__unused NSException *e) {
        }
    }
    if (ids.count == 0) {
        DDA_LOG(@"没有可加入相簿的资产标识");
        return;
    }

    @try {
        PHFetchResult<PHAssetCollection *> *albumResult =
            [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[ albumID ] options:nil];
        PHAssetCollection *album = albumResult.firstObject;
        if (!album) {
            DDA_LOG(@"目标相簿已不存在: %@", albumName);
            return;
        }

        PHFetchResult<PHAsset *> *assetResult = [PHAsset fetchAssetsWithLocalIdentifiers:ids options:nil];
        NSMutableArray<PHAsset *> *assets = [NSMutableArray array];
        for (PHAsset *asset in assetResult) {
            [assets addObject:asset];
        }
        if (assets.count == 0) {
            DDA_LOG(@"新资产还没准备好，跳过归档");
            return;
        }

        [[NSThread currentThread] threadDictionary][kAlbumAddKey] = @YES;
        [[PHPhotoLibrary sharedPhotoLibrary]
            performChanges:^{
              PHAssetCollectionChangeRequest *req =
                  [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album];
              [req addAssets:assets];
            }
            completionHandler:^(BOOL success, NSError *error) {
              [[[NSThread currentThread] threadDictionary] removeObjectForKey:kAlbumAddKey];
              if (success) {
                  DDRefreshPendingExpiry();
                  DDA_LOG(@"已加入相簿「%@」：%lu 个资产", album.localizedTitle ?: albumName,
                          (unsigned long)assets.count);
              } else if (error) {
                  DDA_LOG(@"加入相簿失败: %@", error.localizedDescription);
              }
            }];
    } @catch (NSException *e) {
        DDA_LOG(@"加入相簿异常: %@", e);
    }
}

#pragma mark - performChanges hook（两段式：原事务照常，事后归档）

static void (*origPerformChanges)(id, SEL, id, id);

static void DDPerformChanges(id self, SEL _cmd, id changes, id completion) {
    NSString *albumID = DDPendingAlbumID();

    // 自己发起的归档事务 / 没有选相簿 / 系统内部调用：完全透传
    if (!albumID.length || [[NSThread currentThread] threadDictionary][kAlbumAddKey]) {
        origPerformChanges(self, _cmd, changes, completion);
        return;
    }

    NSString *albumName = nil;
    @synchronized([DYYYAlbum class]) {
        albumName = [gPendingAlbumName copy];
    }

    __block NSArray *placeholders = nil;
    id wrappedChanges = ^{
      NSMutableArray *collector = [NSMutableArray array];
      [[NSThread currentThread] threadDictionary][kCollectorKey] = collector;
      @try {
          if (changes) {
              ((void (^)(void))changes)();
          }
      } @finally {
          [[[NSThread currentThread] threadDictionary] removeObjectForKey:kCollectorKey];
      }
      placeholders = [collector copy];
    };

    id wrappedCompletion = ^(BOOL success, NSError *error) {
      // 先把结果原样交回，保证 DYYY 的保存流程不受影响
      if (completion) {
          ((void (^)(BOOL, NSError *))completion)(success, error);
      }
      if (success && placeholders.count > 0) {
          DDAddAssetsToAlbum(albumID, albumName, placeholders);
      }
    };

    origPerformChanges(self, _cmd, wrappedChanges, wrappedCompletion);
}

static IMP DDReplaceClassMethod(Class cls, SEL sel, IMP newIMP) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) {
        return NULL;
    }
    return method_setImplementation(m, newIMP);
}

static PHAssetChangeRequest *(*origCRImage)(id, SEL, UIImage *);
static PHAssetChangeRequest *DDCRImage(id self, SEL _cmd, UIImage *image) {
    PHAssetChangeRequest *req = origCRImage(self, _cmd, image);
    DDCollectRequest(req);
    return req;
}

static PHAssetChangeRequest *(*origCRVideoURL)(id, SEL, NSURL *);
static PHAssetChangeRequest *DDCRVideoURL(id self, SEL _cmd, NSURL *url) {
    PHAssetChangeRequest *req = origCRVideoURL(self, _cmd, url);
    DDCollectRequest(req);
    return req;
}

static PHAssetChangeRequest *(*origCRImageURL)(id, SEL, NSURL *);
static PHAssetChangeRequest *DDCRImageURL(id self, SEL _cmd, NSURL *url) {
    PHAssetChangeRequest *req = origCRImageURL(self, _cmd, url);
    DDCollectRequest(req);
    return req;
}

static PHAssetCreationRequest *(*origCRAsset)(id, SEL);
static PHAssetCreationRequest *DDCRAsset(id self, SEL _cmd) {
    PHAssetCreationRequest *req = origCRAsset(self, _cmd);
    DDCollectRequest(req);
    return req;
}

static void DDInstallPhotoHooks(void) {
    @try {
        Class plc = [PHPhotoLibrary class];
        Method m = class_getInstanceMethod(plc, @selector(performChanges:completionHandler:));
        if (m) {
            origPerformChanges =
                (void (*)(id, SEL, id, id))method_setImplementation(m, (IMP)DDPerformChanges);
        } else {
            DDA_LOG(@"PHPhotoLibrary performChanges 不存在，归档功能不可用");
        }

        Class acr = [PHAssetChangeRequest class];
        origCRImage = (PHAssetChangeRequest * (*)(id, SEL, UIImage *))
            DDReplaceClassMethod(acr, @selector(creationRequestForAssetFromImage:), (IMP)DDCRImage);
        origCRVideoURL = (PHAssetChangeRequest * (*)(id, SEL, NSURL *))
            DDReplaceClassMethod(acr, @selector(creationRequestForAssetFromVideoAtFileURL:), (IMP)DDCRVideoURL);
        if ([acr respondsToSelector:@selector(creationRequestForAssetFromImageAtFileURL:)]) {
            origCRImageURL = (PHAssetChangeRequest * (*)(id, SEL, NSURL *))
                DDReplaceClassMethod(acr, @selector(creationRequestForAssetFromImageAtFileURL:), (IMP)DDCRImageURL);
        }

        Class acnr = [PHAssetCreationRequest class];
        if ([acnr respondsToSelector:@selector(creationRequestForAsset)]) {
            origCRAsset = (PHAssetCreationRequest * (*)(id, SEL))
                DDReplaceClassMethod(acnr, @selector(creationRequestForAsset), (IMP)DDCRAsset);
        }

        DDA_LOG(@"PhotoKit hooks 已安装");
    } @catch (NSException *e) {
        DDA_LOG(@"安装 PhotoKit hooks 失败: %@", e);
    }
}

#pragma mark - DYYY 下载入口 hook

static void (*origDownloadMedia)(id, SEL, NSURL *, NSInteger, NSURL *, id);
static void (*origDownloadMediaProgress)(id, SEL, NSURL *, NSInteger, NSURL *, id, id);
static void (*origDownloadAllImages)(id, SEL, id);
static void (*origDownloadAllImagesProgress)(id, SEL, id, id, id);
static void (*origDownloadAllLivePhotos)(id, SEL, id);
static void (*origDownloadAllLivePhotosProgress)(id, SEL, id, id, id);
static void (*origSaveCommentImages)(id, SEL, id, NSInteger, id);
static void (*origDownloadLivePhoto)(id, SEL, NSURL *, NSURL *, id);
static void (*origSaveMedia)(id, SEL, NSURL *, NSInteger, id);
static void (*origSaveMediaDesc)(id, SEL, NSURL *, NSInteger, NSString *, id);

static BOOL DDSessionActive(void) {
    @synchronized([DYYYAlbum class]) {
        return DDNow() <= gPendingExpiry;
    }
}

static BOOL DDIsAudioURL(NSURL *url) {
    static NSSet<NSString *> *exts = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      exts = [NSSet setWithArray:@[ @"mp3", @"m4a", @"aac", @"wav", @"flac", @"ogg", @"caf" ]];
    });
    return [exts containsObject:url.pathExtension.lowercaseString];
}

static void DDDownloadMedia(id self, SEL _cmd, NSURL *url, NSInteger mediaType, NSURL *audio, id completion) {
    if (DDIsAudioURL(url)) {
        if (origDownloadMedia) {
            origDownloadMedia(self, _cmd, url, mediaType, audio, completion);
        }
        return;
    }
    DDPresentPicker(^(BOOL go) {
      if (!go) {
          DDA_LOG(@"用户取消下载");
          if (completion) {
              ((void (^)(BOOL))completion)(NO);
          }
          return;
      }
      if (origDownloadMedia) {
          origDownloadMedia(self, _cmd, url, mediaType, audio, completion);
      }
    });
}

static void DDDownloadMediaProgress(id self, SEL _cmd, NSURL *url, NSInteger mediaType, NSURL *audio,
                                    id progress, id completion) {
    if (DDIsAudioURL(url)) {
        if (origDownloadMediaProgress) {
            origDownloadMediaProgress(self, _cmd, url, mediaType, audio, progress, completion);
        }
        return;
    }
    DDPresentPicker(^(BOOL go) {
      if (!go) {
          DDA_LOG(@"用户取消下载");
          return;
      }
      if (origDownloadMediaProgress) {
          origDownloadMediaProgress(self, _cmd, url, mediaType, audio, progress, completion);
      }
    });
}

static void DDDownloadAllImages(id self, SEL _cmd, id images) {
    DDPresentPicker(^(BOOL go) {
      if (!go) {
          DDA_LOG(@"用户取消下载");
          return;
      }
      if (origDownloadAllImages) {
          origDownloadAllImages(self, _cmd, images);
      }
    });
}

static void DDDownloadAllImagesProgress(id self, SEL _cmd, id images, id progress, id completion) {
    DDPresentPicker(^(BOOL go) {
      if (!go) {
          DDA_LOG(@"用户取消下载");
          return;
      }
      if (origDownloadAllImagesProgress) {
          origDownloadAllImagesProgress(self, _cmd, images, progress, completion);
      }
    });
}

static void DDDownloadAllLivePhotos(id self, SEL _cmd, id photos) {
    DDPresentPicker(^(BOOL go) {
      if (!go) {
          DDA_LOG(@"用户取消下载");
          return;
      }
      if (origDownloadAllLivePhotos) {
          origDownloadAllLivePhotos(self, _cmd, photos);
      }
    });
}

static void DDDownloadAllLivePhotosProgress(id self, SEL _cmd, id photos, id progress, id completion) {
    DDPresentPicker(^(BOOL go) {
      if (!go) {
          DDA_LOG(@"用户取消下载");
          return;
      }
      if (origDownloadAllLivePhotosProgress) {
          origDownloadAllLivePhotosProgress(self, _cmd, photos, progress, completion);
      }
    });
}

static void DDSaveCommentImages(id self, SEL _cmd, id images, NSInteger index, id completion) {
    DDPresentPicker(^(BOOL go) {
      if (!go) {
          DDA_LOG(@"用户取消下载");
          return;
      }
      if (origSaveCommentImages) {
          origSaveCommentImages(self, _cmd, images, index, completion);
      }
    });
}

static void DDDownloadLivePhoto(id self, SEL _cmd, NSURL *imageURL, NSURL *videoURL, id completion) {
    DDPresentPicker(^(BOOL go) {
      if (!go) {
          DDA_LOG(@"用户取消下载");
          return;
      }
      if (origDownloadLivePhoto) {
          origDownloadLivePhoto(self, _cmd, imageURL, videoURL, completion);
      }
    });
}

// 兜底：没走上面入口、直接调保存的，也在保存前问一次
static void DDSaveMedia(id self, SEL _cmd, NSURL *url, NSInteger mediaType, id completion) {
    if (DDSessionActive()) {
        if (origSaveMedia) {
            origSaveMedia(self, _cmd, url, mediaType, completion);
        }
        return;
    }
    DDPresentPicker(^(BOOL go) {
      if (!go) {
          DDA_LOG(@"用户取消保存");
          if (completion) {
              ((void (^)(BOOL))completion)(NO);
          }
          return;
      }
      if (origSaveMedia) {
          origSaveMedia(self, _cmd, url, mediaType, completion);
      }
    });
}

static void DDSaveMediaDesc(id self, SEL _cmd, NSURL *url, NSInteger mediaType, NSString *desc,
                            id completion) {
    if (DDSessionActive()) {
        if (origSaveMediaDesc) {
            origSaveMediaDesc(self, _cmd, url, mediaType, desc, completion);
        }
        return;
    }
    DDPresentPicker(^(BOOL go) {
      if (!go) {
          DDA_LOG(@"用户取消保存");
          if (completion) {
              ((void (^)(BOOL))completion)(NO);
          }
          return;
      }
      if (origSaveMediaDesc) {
          origSaveMediaDesc(self, _cmd, url, mediaType, desc, completion);
      }
    });
}

static NSUInteger DDInstallDYYYHooks(void) {
    if (gDYYYHooksInstalled) {
        return 1;
    }
    Class cls = objc_getClass("DYYYManager");
    if (!cls) {
        return 0;
    }

    @try {
        NSUInteger installed = 0;
        IMP imp = DDReplaceClassMethod(cls, @selector(downloadMedia:mediaType:audio:completion:),
                                       (IMP)DDDownloadMedia);
        if (imp) {
            origDownloadMedia = (void (*)(id, SEL, NSURL *, NSInteger, NSURL *, id))imp;
            installed++;
        }

        imp = DDReplaceClassMethod(cls, @selector(downloadMediaWithProgress:mediaType:audio:progress:completion:),
                                   (IMP)DDDownloadMediaProgress);
        if (imp) {
            origDownloadMediaProgress = (void (*)(id, SEL, NSURL *, NSInteger, NSURL *, id, id))imp;
            installed++;
        }

        imp = DDReplaceClassMethod(cls, @selector(downloadAllImages:), (IMP)DDDownloadAllImages);
        if (imp) {
            origDownloadAllImages = (void (*)(id, SEL, id))imp;
            installed++;
        }

        imp = DDReplaceClassMethod(cls, @selector(downloadAllImagesWithProgress:progress:completion:),
                                   (IMP)DDDownloadAllImagesProgress);
        if (imp) {
            origDownloadAllImagesProgress = (void (*)(id, SEL, id, id, id))imp;
            installed++;
        }

        imp = DDReplaceClassMethod(cls, @selector(downloadAllLivePhotos:), (IMP)DDDownloadAllLivePhotos);
        if (imp) {
            origDownloadAllLivePhotos = (void (*)(id, SEL, id))imp;
            installed++;
        }

        imp = DDReplaceClassMethod(cls, @selector(downloadAllLivePhotosWithProgress:progress:completion:),
                                   (IMP)DDDownloadAllLivePhotosProgress);
        if (imp) {
            origDownloadAllLivePhotosProgress = (void (*)(id, SEL, id, id, id))imp;
            installed++;
        }

        imp = DDReplaceClassMethod(cls, @selector(saveCommentImages:currentIndex:completion:),
                                   (IMP)DDSaveCommentImages);
        if (imp) {
            origSaveCommentImages = (void (*)(id, SEL, id, NSInteger, id))imp;
            installed++;
        }

        imp = DDReplaceClassMethod(cls, @selector(downloadLivePhoto:videoURL:completion:),
                                   (IMP)DDDownloadLivePhoto);
        if (imp) {
            origDownloadLivePhoto = (void (*)(id, SEL, NSURL *, NSURL *, id))imp;
            installed++;
        }

        imp = DDReplaceClassMethod(cls, @selector(saveMedia:mediaType:completion:), (IMP)DDSaveMedia);
        if (imp) {
            origSaveMedia = (void (*)(id, SEL, NSURL *, NSInteger, id))imp;
            installed++;
        }

        imp = DDReplaceClassMethod(cls, @selector(saveMedia:mediaType:albumDescription:completion:),
                                   (IMP)DDSaveMediaDesc);
        if (imp) {
            origSaveMediaDesc = (void (*)(id, SEL, NSURL *, NSInteger, NSString *, id))imp;
            installed++;
        }

        gDYYYHooksInstalled = (installed > 0);
        DDA_LOG(@"DYYYManager hooks: %lu 个", (unsigned long)installed);
        return installed;
    } @catch (NSException *e) {
        DDA_LOG(@"安装 DYYYManager hooks 失败: %@", e);
        return 0;
    }
}

static void DDRetryInstall(NSUInteger attempt) {
    if (DDInstallDYYYHooks()) {
        return;
    }
    if (attempt >= 240) {
        DDA_LOG(@"未找到 DYYYManager，仅保留 PhotoKit 兜底");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     DDRetryInstall(attempt + 1);
                   });
}

__attribute__((constructor)) static void DYYYAlbumInit(void) {
    DDA_LOG(@"启动 v1.1.0，日志: %@",
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"dyyyalbum.log"]);
    DDInstallPhotoHooks();
    dispatch_async(dispatch_get_main_queue(), ^{
      DDRetryInstall(0);
    });
}