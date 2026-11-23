//
//  DYYYAlbum — 给 DYYY 的下载流程加「保存到相簿」选择
//  纯 ObjC 运行时 hook，不依赖 CydiaSubstrate
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

#define DDA_LOG(fmt, ...) NSLog(@"[DYYYAlbum] " fmt, ##__VA_ARGS__)

static NSString *const kLastAlbumIDKey = @"DYYYAlbum.lastAlbumID";
static NSString *const kLastAlbumNameKey = @"DYYYAlbum.lastAlbumName";
static NSString *const kCollectorKey = @"DYYYAlbum.placeholderCollector";

// 选好的目标相簿（在下载/保存期间有效）
static NSString *gPendingAlbumID = nil;
static NSString *gPendingAlbumName = nil;
static NSTimeInterval gPendingExpiry = 0;
static BOOL gPickerShowing = NO;
static BOOL gDYYYHooksInstalled = NO;

@interface DYYYAlbum : NSObject
@end

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
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (albumID.length) {
        [d setObject:albumID forKey:kLastAlbumIDKey];
        [d setObject:(albumName ?: @"") forKey:kLastAlbumNameKey];
    } else {
        [d removeObjectForKey:kLastAlbumIDKey];
        [d removeObjectForKey:kLastAlbumNameKey];
    }
    [d synchronize];
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
    PHFetchResult<PHAssetCollection *> *result =
        [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                 subtype:PHAssetCollectionSubtypeAny
                                                 options:nil];
    NSMutableArray<PHAssetCollection *> *albums = [NSMutableArray array];
    for (PHAssetCollection *album in result) {
        if (album.localizedTitle.length) {
            [albums addObject:album];
        }
    }
    [albums sortUsingComparator:^NSComparisonResult(PHAssetCollection *a, PHAssetCollection *b) {
      return [a.localizedTitle localizedCompare:b.localizedTitle];
    }];
    return albums;
}

#pragma mark - 新建相簿

static void DDCreateAlbum(NSString *title, void (^completion)(PHAssetCollection *album)) {
    __block PHObjectPlaceholder *placeholder = nil;
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
          PHFetchResult<PHAssetCollection *> *r =
              [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[ placeholder.localIdentifier ]
                                                                   options:nil];
          PHAssetCollection *album = r.firstObject;
          dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(album);
            }
          });
        }];
}

#pragma mark - 相簿选择弹窗

static void DDPresentPicker(void (^proceed)(BOOL shouldDownload));

static void DDShowNewAlbumAlert(void (^proceed)(BOOL)) {
    UIViewController *top = DDTopViewController();
    if (!top) {
        proceed(YES);
        return;
    }
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

    [sheet addAction:[UIAlertAction actionWithTitle:@"最近项目（不加入相簿）"
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
}

static void DDPresentPicker(void (^proceed)(BOOL)) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (gPickerShowing) {
          // 已有弹窗时直接沿用当前选择，避免连续下载时堆叠弹窗
          proceed(YES);
          return;
      }
      gPickerShowing = YES;

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
    });
}

#pragma mark - PhotoKit：收集新建资产并加入目标相簿

static void (*origPerformChanges)(id, SEL, id, id);

static void DDCollectRequest(id request) {
    if (!request) {
        return;
    }
    NSMutableArray *collector = [[NSThread currentThread] threadDictionary][kCollectorKey];
    if (!collector) {
        return;
    }
    @try {
        PHObjectPlaceholder *placeholder = [request placeholderForCreatedAsset];
        if (placeholder) {
            [collector addObject:placeholder];
        }
    } @catch (NSException *e) {
        DDA_LOG(@"收集资产失败: %@", e);
    }
}

static void DDPerformChanges(id self, SEL _cmd, id changes, id completion) {
    NSString *albumID = DDPendingAlbumID();
    if (!albumID.length) {
        origPerformChanges(self, _cmd, changes, completion);
        return;
    }

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

      if (collector.count == 0) {
          return;
      }

      PHFetchResult<PHAssetCollection *> *result =
          [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[ albumID ] options:nil];
      PHAssetCollection *album = result.firstObject;
      if (!album) {
          DDA_LOG(@"目标相簿不存在: %@", albumID);
          return;
      }
      @try {
          PHAssetCollectionChangeRequest *req =
              [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album];
          [req addAssets:collector];
          @synchronized([DYYYAlbum class]) {
              if (gPendingAlbumID.length) {
                  gPendingExpiry = DDNow() + 900.0;
              }
          }
          DDA_LOG(@"已加入相簿 %@，资产 %lu 个", album.localizedTitle, (unsigned long)collector.count);
      } @catch (NSException *e) {
          DDA_LOG(@"加入相簿失败: %@", e);
      }
    };

    origPerformChanges(self, _cmd, wrappedChanges, completion);
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
    Class plc = [PHPhotoLibrary class];
    Method m = class_getInstanceMethod(plc, @selector(performChanges:completionHandler:));
    if (m) {
        origPerformChanges = (void (*)(id, SEL, id, id))method_setImplementation(m, (IMP)DDPerformChanges);
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

static void DDLogCancelled(void) {
    DDA_LOG(@"用户取消下载");
}

static void DDDownloadMedia(id self, SEL _cmd, NSURL *url, NSInteger mediaType, NSURL *audio, id completion) {
    DDPresentPicker(^(BOOL go) {
      if (!go) {
          DDLogCancelled();
          return;
      }
      if (origDownloadMedia) {
          origDownloadMedia(self, _cmd, url, mediaType, audio, completion);
      }
    });
}

static void DDDownloadMediaProgress(id self, SEL _cmd, NSURL *url, NSInteger mediaType, NSURL *audio,
                                    id progress, id completion) {
    DDPresentPicker(^(BOOL go) {
      if (!go) {
          DDLogCancelled();
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
          DDLogCancelled();
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
          DDLogCancelled();
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
          DDLogCancelled();
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
          DDLogCancelled();
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
          DDLogCancelled();
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
          DDLogCancelled();
          return;
      }
      if (origDownloadLivePhoto) {
          origDownloadLivePhoto(self, _cmd, imageURL, videoURL, completion);
      }
    });
}

// 兜底：没走上面入口、直接保存的，也在保存前问一次
static void DDSaveMedia(id self, SEL _cmd, NSURL *url, NSInteger mediaType, id completion) {
    if (DDSessionActive()) {
        if (origSaveMedia) {
            origSaveMedia(self, _cmd, url, mediaType, completion);
        }
        return;
    }
    DDPresentPicker(^(BOOL go) {
      if (!go) {
          DDLogCancelled();
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
          DDLogCancelled();
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

    NSUInteger installed = 0;
    IMP imp = DDReplaceClassMethod(cls, @selector(downloadMedia:mediaType:audio:completion:), (IMP)DDDownloadMedia);
    if (imp) { origDownloadMedia = (void (*)(id, SEL, NSURL *, NSInteger, NSURL *, id))imp; installed++; }

    imp = DDReplaceClassMethod(cls, @selector(downloadMediaWithProgress:mediaType:audio:progress:completion:),
                               (IMP)DDDownloadMediaProgress);
    if (imp) { origDownloadMediaProgress = (void (*)(id, SEL, NSURL *, NSInteger, NSURL *, id, id))imp; installed++; }

    imp = DDReplaceClassMethod(cls, @selector(downloadAllImages:), (IMP)DDDownloadAllImages);
    if (imp) { origDownloadAllImages = (void (*)(id, SEL, id))imp; installed++; }

    imp = DDReplaceClassMethod(cls, @selector(downloadAllImagesWithProgress:progress:completion:),
                               (IMP)DDDownloadAllImagesProgress);
    if (imp) { origDownloadAllImagesProgress = (void (*)(id, SEL, id, id, id))imp; installed++; }

    imp = DDReplaceClassMethod(cls, @selector(downloadAllLivePhotos:), (IMP)DDDownloadAllLivePhotos);
    if (imp) { origDownloadAllLivePhotos = (void (*)(id, SEL, id))imp; installed++; }

    imp = DDReplaceClassMethod(cls, @selector(downloadAllLivePhotosWithProgress:progress:completion:),
                               (IMP)DDDownloadAllLivePhotosProgress);
    if (imp) { origDownloadAllLivePhotosProgress = (void (*)(id, SEL, id, id, id))imp; installed++; }

    imp = DDReplaceClassMethod(cls, @selector(saveCommentImages:currentIndex:completion:),
                               (IMP)DDSaveCommentImages);
    if (imp) { origSaveCommentImages = (void (*)(id, SEL, id, NSInteger, id))imp; installed++; }

    imp = DDReplaceClassMethod(cls, @selector(downloadLivePhoto:videoURL:completion:),
                               (IMP)DDDownloadLivePhoto);
    if (imp) { origDownloadLivePhoto = (void (*)(id, SEL, NSURL *, NSURL *, id))imp; installed++; }

    imp = DDReplaceClassMethod(cls, @selector(saveMedia:mediaType:completion:), (IMP)DDSaveMedia);
    if (imp) { origSaveMedia = (void (*)(id, SEL, NSURL *, NSInteger, id))imp; installed++; }

    imp = DDReplaceClassMethod(cls, @selector(saveMedia:mediaType:albumDescription:completion:),
                               (IMP)DDSaveMediaDesc);
    if (imp) { origSaveMediaDesc = (void (*)(id, SEL, NSURL *, NSInteger, NSString *, id))imp; installed++; }

    gDYYYHooksInstalled = (installed > 0);
    DDA_LOG(@"DYYYManager hooks: %lu 个", (unsigned long)installed);
    return installed;
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
    DDInstallPhotoHooks();
    dispatch_async(dispatch_get_main_queue(), ^{
      DDRetryInstall(0);
    });
}
