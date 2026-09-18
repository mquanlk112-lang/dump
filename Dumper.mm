// Dumper.mm — clean version
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <sys/mman.h>
#import <objc/runtime.h>
#import <zlib.h>

#pragma mark - mach-o parse

struct mo_info {
    int is64;
    uint64_t max_file_end;
    uint32_t crypt_off;
    uint32_t crypt_size;
    uint32_t crypt_id;
    uint32_t crypt_cmd_off;
};

static BOOL parse_macho(const uint8_t *base, struct mo_info *out) {
    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)base;
    uint32_t magic = mh64->magic;
    int is64;
    uint32_t ncmds, sizeofcmds, header_size;

    if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64) {
        is64 = 1;
        ncmds = mh64->ncmds;
        sizeofcmds = mh64->sizeofcmds;
        header_size = sizeof(struct mach_header_64);
    } else if (magic == MH_MAGIC || magic == MH_CIGAM) {
        is64 = 0;
        const struct mach_header *mh = (const struct mach_header *)base;
        ncmds = mh->ncmds;
        sizeofcmds = mh->sizeofcmds;
        header_size = sizeof(struct mach_header);
    } else return NO;

    memset(out, 0, sizeof(*out));
    out->is64 = is64;

    const uint8_t *cmds = base + header_size;
    uint32_t o = 0;
    for (uint32_t i = 0; i < ncmds && o + 8 <= sizeofcmds; i++) {
        const struct load_command *lc = (const struct load_command *)(cmds + o);
        if (lc->cmdsize == 0) break;

        if (lc->cmd == LC_SEGMENT_64 && is64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
            uint64_t fe = sc->fileoff + sc->filesize;
            if (fe > out->max_file_end) out->max_file_end = fe;
        } else if (lc->cmd == LC_SEGMENT && !is64) {
            const struct segment_command *sc = (const struct segment_command *)lc;
            uint64_t fe = (uint64_t)sc->fileoff + sc->filesize;
            if (fe > out->max_file_end) out->max_file_end = fe;
        } else if (lc->cmd == LC_ENCRYPTION_INFO_64) {
            const struct encryption_info_command_64 *ei =
                (const struct encryption_info_command_64 *)lc;
            out->crypt_off = ei->cryptoff;
            out->crypt_size = ei->cryptsize;
            out->crypt_id = ei->cryptid;
            out->crypt_cmd_off = o + 16;
        } else if (lc->cmd == LC_ENCRYPTION_INFO) {
            const struct encryption_info_command *ei =
                (const struct encryption_info_command *)lc;
            out->crypt_off = ei->cryptoff;
            out->crypt_size = ei->cryptsize;
            out->crypt_id = ei->cryptid;
            out->crypt_cmd_off = o + 16;
        }
        o += lc->cmdsize;
    }
    return YES;
}

#pragma mark - dump

static NSData *dump_main_executable(NSError **err) {
    const struct mach_header *mh = _dyld_get_image_header(0);
    if (!mh) { if (err) *err = [NSError errorWithDomain:@"d" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"no image"}]; return nil; }

    const uint8_t *base = (const uint8_t *)mh;
    struct mo_info info;
    if (!parse_macho(base, &info)) {
        if (err) *err = [NSError errorWithDomain:@"d" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"not macho"}]; return nil;
    }

    if (info.crypt_id != 0 && info.crypt_size > 0) {
        int pg = getpagesize();
        uintptr_t cs = (uintptr_t)base + info.crypt_off;
        uintptr_t as = cs & ~(uintptr_t)(pg - 1);
        uintptr_t ae = (cs + info.crypt_size + pg - 1) & ~(uintptr_t)(pg - 1);
        vm_size_t sz = ae - as;
        vm_protect(mach_task_self(), as, sz, false,
                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        volatile uint8_t s = 0;
        const uint8_t *p = base + info.crypt_off;
        for (uint32_t i = 0; i < info.crypt_size; i += pg) s ^= p[i];
        (void)s;
    }

    uint64_t size = info.max_file_end;
    if (size == 0) { if (err) *err = [NSError errorWithDomain:@"d" code:3
        userInfo:@{NSLocalizedDescriptionKey:@"zero size"}]; return nil; }

    NSMutableData *out = [NSMutableData dataWithLength:size];
    memcpy(out.mutableBytes, base, size);

    if (info.crypt_cmd_off > 0) {
        uint8_t *pp = (uint8_t *)out.mutableBytes + info.crypt_cmd_off;
        *(uint32_t *)pp = 0;
    }
    return out;
}

static BOOL copy_bundle(NSString *src, NSString *dst, NSString *skipName) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:nil];
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:src];
    for (NSString *rel in e) {
        if (skipName && [rel isEqualToString:skipName]) continue;
        NSString *s = [src stringByAppendingPathComponent:rel];
        NSString *d = [dst stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        [fm fileExistsAtPath:s isDirectory:&isDir];
        if (isDir) {
            [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
        } else {
            [fm createDirectoryAtPath:[d stringByDeletingLastPathComponent]
                withIntermediateDirectories:YES attributes:nil error:nil];
            [fm removeItemAtPath:d error:nil];
            [fm copyItemAtPath:s toPath:d error:nil];
        }
    }
    return YES;
}

#pragma mark - zip (store)

static uint32_t g_crc[256];
static void crc_init(void){
    for(uint32_t i=0;i<256;i++){
        uint32_t c=i;
        for(int k=0;k<8;k++) c = (c&1) ? (0xEDB88320 ^ (c>>1)) : (c>>1);
        g_crc[i]=c;
    }
}
static uint32_t crc_buf(const uint8_t*b,size_t n){
    uint32_t c=0xFFFFFFFF;
    for(size_t i=0;i<n;i++) c = g_crc[(c^b[i])&0xFF] ^ (c>>8);
    return c^0xFFFFFFFF;
}
static void w16(FILE*f,uint16_t v){fwrite(&v,1,2,f);}
static void w32(FILE*f,uint32_t v){fwrite(&v,1,4,f);}

static BOOL zip_dir(NSString *srcDir, NSString *outZip) {
    crc_init();
    FILE *out = fopen(outZip.fileSystemRepresentation, "wb");
    if (!out) return NO;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:srcDir];
    for (NSString *rel in en) {
        NSString *full = [srcDir stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        [fm fileExistsAtPath:full isDirectory:&isDir];
        if (!isDir) [files addObject:rel];
    }

    NSMutableData *cd = [NSMutableData data];
    for (NSString *rel in files) {
        NSString *full = [srcDir stringByAppendingPathComponent:rel];
        NSData *data = [NSData dataWithContentsOfFile:full];
        if (!data) continue;

        const char *name = rel.UTF8String;
        uint16_t nlen = (uint16_t)strlen(name);
        uint32_t crc = crc_buf((const uint8_t *)data.bytes, data.length);
        uint32_t sz = (uint32_t)data.length;
        uint32_t lofs = (uint32_t)ftell(out);

        w32(out, 0x04034b50);
        w16(out, 20); w16(out, 0); w16(out, 0);
        w16(out, 0); w16(out, 0);
        w32(out, crc); w32(out, sz); w32(out, sz);
        w16(out, nlen); w16(out, 0);
        fwrite(name, 1, nlen, out);
        fwrite(data.bytes, 1, data.length, out);

        NSMutableData *ent = [NSMutableData data];
        uint16_t v16; uint32_t v32;
        v32 = 0x02014b50; [ent appendBytes:&v32 length:4];
        v16 = 20; [ent appendBytes:&v16 length:2];
        v16 = 20; [ent appendBytes:&v16 length:2];
        v16 = 0;  [ent appendBytes:&v16 length:2];
        v16 = 0;  [ent appendBytes:&v16 length:2];
        v16 = 0;  [ent appendBytes:&v16 length:2];
        v16 = 0;  [ent appendBytes:&v16 length:2];
        [ent appendBytes:&crc length:4];
        [ent appendBytes:&sz length:4];
        [ent appendBytes:&sz length:4];
        [ent appendBytes:&nlen length:2];
        v16 = 0; [ent appendBytes:&v16 length:2];
        v16 = 0; [ent appendBytes:&v16 length:2];
        v16 = 0; [ent appendBytes:&v16 length:2];
        v16 = 0; [ent appendBytes:&v16 length:2];
        v32 = 0; [ent appendBytes:&v32 length:4];
        [ent appendBytes:&lofs length:4];
        [ent appendBytes:name length:nlen];
        [cd appendData:ent];
    }

    uint32_t cdStart = (uint32_t)ftell(out);
    fwrite(cd.bytes, 1, cd.length, out);
    uint32_t cdSize = (uint32_t)cd.length;

    w32(out, 0x06054b50);
    w16(out, 0); w16(out, 0);
    w16(out, (uint16_t)files.count);
    w16(out, (uint16_t)files.count);
    w32(out, cdSize);
    w32(out, cdStart);
    w16(out, 0);
    fclose(out);
    return YES;
}

#pragma mark - dump full

static NSString *run_full_dump(void) {
    NSFileManager *fm = NSFileManager.defaultManager;

    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *ts = [NSString stringWithFormat:@"dump_%ld",
                    (long)[[NSDate date] timeIntervalSince1970]];
    NSString *root = [docs stringByAppendingPathComponent:ts];
    NSString *work = [root stringByAppendingPathComponent:@"work"];
    [fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *execName   = [[NSBundle mainBundle] infoDictionary][@"CFBundleExecutable"];
    NSString *appName    = bundlePath.lastPathComponent;

    NSString *payload = [work stringByAppendingPathComponent:@"Payload"];
    NSString *appOut  = [payload stringByAppendingPathComponent:appName];
    [fm createDirectoryAtPath:appOut withIntermediateDirectories:YES attributes:nil error:nil];

    copy_bundle(bundlePath, appOut, execName);

    NSError *err = nil;
    NSData *bin = dump_main_executable(&err);
    if (!bin) { NSLog(@"[DUMP] fail: %@", err.localizedDescription); return nil; }
    [bin writeToFile:[appOut stringByAppendingPathComponent:execName] atomically:YES];

    NSString *ver = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"] ?: @"?";
    NSString *ipaPath = [root stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%@_%@.ipa", execName, ver]];

    if (!zip_dir(work, ipaPath)) { NSLog(@"[DUMP] zip fail"); return nil; }

    [fm removeItemAtPath:work error:nil];
    return ipaPath;
}

#pragma mark - UI

@interface DumperUI : NSObject
@property (nonatomic, strong) UIWindow *win;
@property (nonatomic, strong) UIView *host;
@property (nonatomic, strong) UIButton *btn;
@property (nonatomic, strong) UILabel *info;
@property (nonatomic, assign) BOOL busy;
@end

@implementation DumperUI

+ (instancetype)shared { static DumperUI *u; static dispatch_once_t t;
    dispatch_once(&t, ^{ u = [DumperUI new]; }); return u; }

- (void)build {
    if (self.win) return;
    CGRect sc = [UIScreen mainScreen].bounds;
    CGFloat sz = 84, x = sc.size.width - sz - 20, y = 100;

    self.win = [[UIWindow alloc] initWithFrame:sc];
    self.win.windowLevel = UIWindowLevelAlert + 1000;
    self.win.backgroundColor = [UIColor clearColor];
    self.win.rootViewController = [UIViewController new];
    self.win.hidden = NO;

    self.host = [[UIView alloc] initWithFrame:CGRectMake(x, y, sz, sz + 24)];
    [self.win.rootViewController.view addSubview:self.host];

    self.btn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.btn.frame = CGRectMake(0, 0, sz, sz);
    self.btn.backgroundColor = [UIColor colorWithRed:1 green:0.16 blue:0.28 alpha:0.92];
    self.btn.layer.cornerRadius = sz / 2;
    self.btn.layer.shadowColor = UIColor.blackColor.CGColor;
    self.btn.layer.shadowRadius = 12;
    self.btn.layer.shadowOpacity = 0.55;
    self.btn.layer.shadowOffset = CGSizeMake(0, 4);
    self.btn.layer.borderWidth = 1.5;
    self.btn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
    [self.btn setTitle:@"DUMP" forState:UIControlStateNormal];
    [self.btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.btn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.btn addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
    [self.host addSubview:self.btn];

    self.info = [[UILabel alloc] initWithFrame:CGRectMake(0, sz + 2, sz, 20)];
    self.info.text = @"tap to dump";
    self.info.textColor = UIColor.whiteColor;
    self.info.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    self.info.textAlignment = NSTextAlignmentCenter;
    self.info.layer.shadowColor = UIColor.blackColor.CGColor;
    self.info.layer.shadowRadius = 3;
    self.info.layer.shadowOpacity = 1;
    self.info.layer.shadowOffset = CGSizeMake(0, 1);
    [self.host addSubview:self.info];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(onPan:)];
    [self.host addGestureRecognizer:pan];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:g.view.superview];
    CGPoint c = g.view.center;
    c.x += t.x; c.y += t.y;
    CGRect sb = g.view.superview.bounds;
    c.x = MAX(46, MIN(sb.size.width - 46, c.x));
    c.y = MAX(60, MIN(sb.size.height - 80, c.y));
    g.view.center = c;
    [g setTranslation:CGPointZero inView:g.view.superview];
}

- (void)alert:(NSString *)title msg:(NSString *)msg ipa:(NSString *)path {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    if (path) {
        [ac addAction:[UIAlertAction actionWithTitle:@"📤 share"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
                UIActivityViewController *av = [[UIActivityViewController alloc]
                    initWithActivityItems:@[[NSURL fileURLWithPath:path]]
                    applicationActivities:nil];
                [self.win.rootViewController presentViewController:av animated:YES completion:nil];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"📋 copy path"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
                UIPasteboard.generalPasteboard.string = path;
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleCancel handler:nil]];
    [self.win.rootViewController presentViewController:ac animated:YES completion:nil];
}

- (void)onTap {
    if (self.busy) return;
    self.busy = YES;
    self.btn.enabled = NO;
    self.info.text = @"dumping...";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *ipa = run_full_dump();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.btn.enabled = YES;
            if (ipa) {
                self.info.text = @"done ✓";
                [self alert:@"✅ dump done"
                       msg:[NSString stringWithFormat:@"saved to:\n%@", ipa]
                       ipa:ipa];
            } else {
                self.info.text = @"fail";
                [self alert:@"❌ dump fail" msg:@"check Console.app log" ipa:nil];
            }
        });
    });
}

@end

__attribute__((constructor))
static void init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[DumperUI shared] build];
    });
}
