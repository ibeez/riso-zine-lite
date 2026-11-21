#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>

static void usage(void) {
    fprintf(stderr,
        "Usage:\n"
        "  cutout <input> [output.png] [options]\n"
        "  cutout --dir <folder> [--out <folder>] [options]\n\n"
        "Modes:\n"
        "  Default           Apple Vision subject lift + sharp razor-blade faceted edges\n"
        "  --soft            Keep smooth Apple Vision alpha edge (disable razor-blade facets)\n"
        "  --facets <px>     Razor-blade facet size in px (default: auto ~1%% of image size)\n"
        "  --margin <px>     Expand (+) or inset (-) cut edge in px (default: 0)\n"
        "  --paper           Knock out bright paper background to alpha (engravings/diagrams)\n"
        "  --threshold <f>   Luminance threshold for --paper mode (default: 0.86)\n"
        "  --razor-only      Apply razor-blade polygon cut to an existing transparent PNG\n"
        "  --no-crop         Keep original canvas dimensions instead of tightly cropping\n");
    exit(1);
}

static BOOL savePNG(CGImageRef cgImage, NSURL *url, NSError **error) {
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (!dest) {
        if (error) *error = [NSError errorWithDomain:@"cutout" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create PNG destination"}];
        return NO;
    }
    CGImageDestinationAddImage(dest, cgImage, NULL);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    if (!ok && error) {
        *error = [NSError errorWithDomain:@"cutout" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Failed to write PNG"}];
    }
    return ok;
}

static CGImageRef loadCGImage(NSURL *url) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    return img;
}

static CGImageRef tightCrop(CGImageRef cgImage, int pad) {
    size_t w = CGImageGetWidth(cgImage);
    size_t h = CGImageGetHeight(cgImage);
    if (w == 0 || h == 0) return CGImageRetain(cgImage);
    size_t bpr = w * 4;
    uint8_t *pixels = calloc(h, bpr);
    if (!pixels) return CGImageRetain(cgImage);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, bpr, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(pixels); return CGImageRetain(cgImage); }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImage);
    CGContextRelease(ctx);

    int minX = (int)w, maxX = -1, minY = (int)h, maxY = -1;
    for (int y = 0; y < (int)h; y++) {
        uint8_t *row = pixels + y * bpr;
        for (int x = 0; x < (int)w; x++) {
            if (row[x * 4 + 3] > 10) {
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
                if (y < minY) minY = y;
                if (y > maxY) maxY = y;
            }
        }
    }
    free(pixels);
    if (maxX < minX || maxY < minY) return CGImageRetain(cgImage);
    int rx = MAX(0, minX - pad);
    int ry = MAX(0, minY - pad);
    int rw = MIN((int)w - rx, (maxX - minX + 1) + pad * 2);
    int rh = MIN((int)h - ry, (maxY - minY + 1) + pad * 2);
    CGImageRef cropped = CGImageCreateWithImageInRect(cgImage, CGRectMake(rx, ry, rw, rh));
    return cropped ? cropped : CGImageRetain(cgImage);
}

// ==================== RAZOR-BLADE POLYGON CUTOUT ENGINE ====================

typedef struct { float x, y; } Pt;

static float ptLineDist(Pt p, Pt a, Pt b) {
    float dx = b.x - a.x, dy = b.y - a.y;
    float len2 = dx * dx + dy * dy;
    if (len2 < 1e-6f) return hypotf(p.x - a.x, p.y - a.y);
    float num = fabsf(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x);
    return num / sqrtf(len2);
}

static void rdpRec(const Pt *pts, int start, int end, float eps, uint8_t *keep) {
    if (end <= start + 1) return;
    float maxD = -1.0f;
    int idx = -1;
    for (int i = start + 1; i < end; i++) {
        float d = ptLineDist(pts[i], pts[start], pts[end]);
        if (d > maxD) { maxD = d; idx = i; }
    }
    if (maxD > eps && idx > start) {
        keep[idx] = 1;
        rdpRec(pts, start, idx, eps, keep);
        rdpRec(pts, idx, end, eps, keep);
    }
}

static Pt *simplifyClosedLoop(const Pt *pts, int n, float eps, int *outCount) {
    if (n < 4) { *outCount = 0; return NULL; }
    // Split closed loop at two farthest points for balanced RDP simplification
    int a = 0;
    float best = -1.0f;
    for (int i = 1; i < n; i++) {
        float d = (pts[i].x - pts[0].x) * (pts[i].x - pts[0].x) + (pts[i].y - pts[0].y) * (pts[i].y - pts[0].y);
        if (d > best) { best = d; a = i; }
    }
    int b = a;
    best = -1.0f;
    for (int i = 0; i < n; i++) {
        float d = (pts[i].x - pts[a].x) * (pts[i].x - pts[a].x) + (pts[i].y - pts[a].y) * (pts[i].y - pts[a].y);
        if (d > best) { best = d; b = i; }
    }
    if (a == b) { *outCount = 0; return NULL; }

    // Chain 1: a -> b, Chain 2: b -> a
    int n1 = ((b - a + n) % n) + 1;
    int n2 = ((a - b + n) % n) + 1;
    Pt *c1 = malloc(sizeof(Pt) * n1);
    Pt *c2 = malloc(sizeof(Pt) * n2);
    uint8_t *k1 = calloc(n1, 1);
    uint8_t *k2 = calloc(n2, 1);
    for (int i = 0; i < n1; i++) c1[i] = pts[(a + i) % n];
    for (int i = 0; i < n2; i++) c2[i] = pts[(b + i) % n];
    k1[0] = k1[n1 - 1] = 1;
    k2[0] = k2[n2 - 1] = 1;
    rdpRec(c1, 0, n1 - 1, eps, k1);
    rdpRec(c2, 0, n2 - 1, eps, k2);

    Pt *out = malloc(sizeof(Pt) * (n1 + n2));
    int count = 0;
    for (int i = 0; i < n1 - 1; i++) if (k1[i]) out[count++] = c1[i];
    for (int i = 0; i < n2 - 1; i++) if (k2[i]) out[count++] = c2[i];

    free(c1); free(c2); free(k1); free(k2);
    *outCount = count;
    return out;
}

static void morphMask(uint8_t *mask, int w, int h, int radius) {
    if (radius == 0) return;
    int dilate = radius > 0 ? 1 : 0;
    int r = abs(radius);
    uint8_t *tmp = malloc((size_t)w * h);
    uint8_t *dst = malloc((size_t)w * h);
    // Horizontal pass
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint8_t v = dilate ? 0 : 1;
            int x0 = MAX(0, x - r), x1 = MIN(w - 1, x + r);
            for (int xx = x0; xx <= x1; xx++) {
                if (dilate ? mask[y * w + xx] : !mask[y * w + xx]) { v = dilate ? 1 : 0; break; }
            }
            tmp[y * w + x] = v;
        }
    }
    // Vertical pass
    for (int y = 0; y < h; y++) {
        int y0 = MAX(0, y - r), y1 = MIN(h - 1, y + r);
        for (int x = 0; x < w; x++) {
            uint8_t v = dilate ? 0 : 1;
            for (int yy = y0; yy <= y1; yy++) {
                if (dilate ? tmp[yy * w + x] : !tmp[yy * w + x]) { v = dilate ? 1 : 0; break; }
            }
            dst[y * w + x] = v;
        }
    }
    memcpy(mask, dst, (size_t)w * h);
    free(tmp); free(dst);
}

static CGImageRef applyRazorCut(CGImageRef srcImage, CGImageRef maskAlphaImage, double facetsPx, int marginPx) {
    int w = (int)CGImageGetWidth(maskAlphaImage);
    int h = (int)CGImageGetHeight(maskAlphaImage);
    if (w <= 0 || h <= 0) return CGImageRetain(srcImage);

    // 1. Read alpha channel from maskAlphaImage into binary mask
    size_t bpr = (size_t)w * 4;
    uint8_t *pixels = calloc((size_t)h, bpr);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef mctx = CGBitmapContextCreate(pixels, w, h, 8, bpr, cs, kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(mctx, CGRectMake(0, 0, w, h), maskAlphaImage);
    CGContextRelease(mctx);

    uint8_t *mask = calloc((size_t)w * h, 1);
    for (int y = 0; y < h; y++) {
        uint8_t *row = pixels + (size_t)y * bpr;
        for (int x = 0; x < w; x++) {
            mask[y * w + x] = (row[x * 4 + 3] > 140) ? 1 : 0;
        }
    }
    free(pixels);

    if (marginPx != 0) morphMask(mask, w, h, marginPx);

    // 2. Build directed boundary edges on the (w+1) x (h+1) vertex grid
    int gw = w + 1, gh = h + 1;
    size_t vCount = (size_t)gw * gh;
    // Each grid vertex has at most 2 outgoing boundary edges
    int32_t *outTo = malloc(vCount * 2 * sizeof(int32_t));
    uint8_t *outCnt = calloc(vCount, 1);
    uint8_t *outUsed = calloc(vCount * 2, 1);

    #define ADD_EDGE(x1, y1, x2, y2) do { \
        int32_t _u = (y1) * gw + (x1); \
        int32_t _v = (y2) * gw + (x2); \
        if (outCnt[_u] < 2) { outTo[(size_t)_u * 2 + outCnt[_u]] = _v; outCnt[_u]++; } \
    } while (0)

    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            if (!mask[y * w + x]) continue;
            if (y == 0     || !mask[(y - 1) * w + x]) ADD_EDGE(x, y, x + 1, y);
            if (x == w - 1 || !mask[y * w + (x + 1)]) ADD_EDGE(x + 1, y, x + 1, y + 1);
            if (y == h - 1 || !mask[(y + 1) * w + x]) ADD_EDGE(x + 1, y + 1, x, y + 1);
            if (x == 0     || !mask[y * w + (x - 1)]) ADD_EDGE(x, y + 1, x, y);
        }
    }
    #undef ADD_EDGE
    free(mask);

    // 3. Stitch directed edges into closed loops and simplify via RDP
    float eps = (facetsPx > 0.0) ? (float)facetsPx : fmaxf(3.5f, 0.011f * (float)MAX(w, h));
    CGMutablePathRef clipPath = CGPathCreateMutable();
    int loopCap = 4096;
    Pt *loopPts = malloc(sizeof(Pt) * loopCap);

    for (size_t u = 0; u < vCount; u++) {
        for (int k = 0; k < outCnt[u]; k++) {
            if (outUsed[u * 2 + k]) continue;
            int len = 0;
            int32_t cur = (int32_t)u;
            int edgeIdx = k;
            while (1) {
                outUsed[(size_t)cur * 2 + edgeIdx] = 1;
                if (len >= loopCap) {
                    loopCap *= 2;
                    loopPts = realloc(loopPts, sizeof(Pt) * loopCap);
                }
                loopPts[len].x = (float)(cur % gw);
                loopPts[len].y = (float)(cur / gw);
                len++;
                int32_t nxt = outTo[(size_t)cur * 2 + edgeIdx];
                if (nxt == (int32_t)u) break;
                int found = -1;
                for (int j = 0; j < outCnt[nxt]; j++) {
                    if (!outUsed[(size_t)nxt * 2 + j]) { found = j; break; }
                }
                if (found < 0) break;
                cur = nxt;
                edgeIdx = found;
            }
            if (len < 24) continue; // drop dust specks
            int simpN = 0;
            Pt *simp = simplifyClosedLoop(loopPts, len, eps, &simpN);
            if (simp && simpN >= 3) {
                // Flip y -> h - y for CGContext bottom-up coordinates
                CGPathMoveToPoint(clipPath, NULL, simp[0].x, (CGFloat)h - simp[0].y);
                for (int i = 1; i < simpN; i++) {
                    CGPathAddLineToPoint(clipPath, NULL, simp[i].x, (CGFloat)h - simp[i].y);
                }
                CGPathCloseSubpath(clipPath);
            }
            free(simp);
        }
    }
    free(loopPts); free(outTo); free(outCnt); free(outUsed);

    // 4. Render original full-resolution source image clipped cleanly by the razor polygon
    uint8_t *outBuf = calloc((size_t)h, bpr);
    CGContextRef outCtx = CGBitmapContextCreate(outBuf, w, h, 8, bpr, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CGContextSetShouldAntialias(outCtx, true);
    CGContextAddPath(outCtx, clipPath);
    CGContextEOClip(outCtx);
    CGContextDrawImage(outCtx, CGRectMake(0, 0, w, h), srcImage);
    CGImageRef result = CGBitmapContextCreateImage(outCtx);
    CGPathRelease(clipPath);
    CGContextRelease(outCtx);
    free(outBuf);
    return result;
}

static CGImageRef paperKnockout(CGImageRef cgImage, double threshold) {
    size_t w = CGImageGetWidth(cgImage);
    size_t h = CGImageGetHeight(cgImage);
    size_t bpr = w * 4;
    uint8_t *pixels = calloc(h, bpr);
    if (!pixels) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, bpr, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(pixels); return NULL; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImage);

    double low = MAX(0.0, threshold - 0.14);
    double span = MAX(0.01, threshold - low);
    size_t count = h * bpr;
    for (size_t i = 0; i < count; i += 4) {
        double r = pixels[i] / 255.0;
        double g = pixels[i + 1] / 255.0;
        double b = pixels[i + 2] / 255.0;
        double a = pixels[i + 3] / 255.0;
        double lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        double keep = (lum >= threshold) ? 0.0 : (lum <= low ? 1.0 : 1.0 - (lum - low) / span);
        double na = a * keep;
        pixels[i]     = (uint8_t)MAX(0, MIN(255, (int)(r * keep * 255.0)));
        pixels[i + 1] = (uint8_t)MAX(0, MIN(255, (int)(g * keep * 255.0)));
        pixels[i + 2] = (uint8_t)MAX(0, MIN(255, (int)(b * keep * 255.0)));
        pixels[i + 3] = (uint8_t)MAX(0, MIN(255, (int)(na * 255.0)));
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    free(pixels);
    return out;
}

static CGImageRef visionCutout(NSURL *inputURL, CIContext *ciContext, BOOL razorMode, double facetsPx, int marginPx, NSError **error) {
    CIImage *ciInput = [CIImage imageWithContentsOfURL:inputURL options:@{kCIImageApplyOrientationProperty: @YES}];
    if (!ciInput) {
        if (error) *error = [NSError errorWithDomain:@"cutout" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not read image: %@", inputURL.path]}];
        return NULL;
    }
    VNGenerateForegroundInstanceMaskRequest *request = [[VNGenerateForegroundInstanceMaskRequest alloc] init];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:ciInput options:@{}];
    if (![handler performRequests:@[request] error:error]) return NULL;
    VNInstanceMaskObservation *obs = request.results.firstObject;
    if (!obs) {
        if (error) *error = [NSError errorWithDomain:@"cutout" code:4 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"No foreground subject detected in %@", inputURL.lastPathComponent]}];
        return NULL;
    }
    CVPixelBufferRef maskBuf = [obs generateScaledMaskForImageForInstances:obs.allInstances fromRequestHandler:handler error:error];
    if (!maskBuf) return NULL;
    CIImage *maskCI = [CIImage imageWithCVPixelBuffer:maskBuf];
    CIFilter *blend = [CIFilter filterWithName:@"CIBlendWithMask"];
    [blend setValue:ciInput forKey:kCIInputImageKey];
    [blend setValue:[CIImage emptyImage] forKey:kCIInputBackgroundImageKey];
    [blend setValue:maskCI forKey:kCIInputMaskImageKey];
    CIImage *outCI = blend.outputImage;
    CGImageRef cgMasked = outCI ? [ciContext createCGImage:outCI fromRect:ciInput.extent] : NULL;
    CVPixelBufferRelease(maskBuf);
    if (!cgMasked) {
        if (error) *error = [NSError errorWithDomain:@"cutout" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Failed to render masked image"}];
        return NULL;
    }
    if (!razorMode) return cgMasked;

    // Render unmasked original CGImage so razor facets slice straight through real pixels with zero soft halo
    CGImageRef cgOrig = [ciContext createCGImage:ciInput fromRect:ciInput.extent];
    CGImageRef cgRazor = applyRazorCut(cgOrig ?: cgMasked, cgMasked, facetsPx, marginPx);
    if (cgOrig) CGImageRelease(cgOrig);
    CGImageRelease(cgMasked);
    return cgRazor;
}

static BOOL processFile(NSURL *inURL, NSURL *outURL, BOOL paperMode, BOOL razorOnly, BOOL razorMode, double facetsPx, int marginPx, double threshold, BOOL doCrop, CIContext *ciContext, NSError **error) {
    CGImageRef cg = NULL;
    if (razorOnly) {
        CGImageRef src = loadCGImage(inURL);
        if (!src) {
            if (error) *error = [NSError errorWithDomain:@"cutout" code:7 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not read image: %@", inURL.path]}];
            return NO;
        }
        cg = applyRazorCut(src, src, facetsPx, marginPx);
        CGImageRelease(src);
    } else if (paperMode) {
        CGImageRef src = loadCGImage(inURL);
        if (!src) {
            if (error) *error = [NSError errorWithDomain:@"cutout" code:7 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not read image: %@", inURL.path]}];
            return NO;
        }
        cg = paperKnockout(src, threshold);
        CGImageRelease(src);
        if (!cg) {
            if (error) *error = [NSError errorWithDomain:@"cutout" code:8 userInfo:@{NSLocalizedDescriptionKey: @"Paper knockout failed"}];
            return NO;
        }
    } else {
        cg = visionCutout(inURL, ciContext, razorMode, facetsPx, marginPx, error);
        if (!cg) return NO;
    }
    if (doCrop) {
        CGImageRef cropped = tightCrop(cg, 6);
        CGImageRelease(cg);
        cg = cropped;
    }
    BOOL ok = savePNG(cg, outURL, error);
    if (ok) {
        printf("OK  %s -> %s (%zux%zu)\n", inURL.lastPathComponent.UTF8String, outURL.lastPathComponent.UTF8String, CGImageGetWidth(cg), CGImageGetHeight(cg));
    }
    CGImageRelease(cg);
    return ok;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) usage();
        NSString *dirMode = nil, *outDir = nil;
        BOOL paperMode = NO, razorOnly = NO, razorMode = YES, doCrop = YES;
        double threshold = 0.86, facetsPx = 0.0;
        int marginPx = 0;
        NSMutableArray<NSString *> *pos = [NSMutableArray array];

        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"]) usage();
            else if ([arg isEqualToString:@"--dir"] && i + 1 < argc) dirMode = [NSString stringWithUTF8String:argv[++i]];
            else if ([arg isEqualToString:@"--out"] && i + 1 < argc) outDir = [NSString stringWithUTF8String:argv[++i]];
            else if ([arg isEqualToString:@"--paper"]) paperMode = YES;
            else if ([arg isEqualToString:@"--razor-only"]) razorOnly = YES;
            else if ([arg isEqualToString:@"--soft"]) razorMode = NO;
            else if ([arg isEqualToString:@"--facets"] && i + 1 < argc) facetsPx = atof(argv[++i]);
            else if ([arg isEqualToString:@"--margin"] && i + 1 < argc) marginPx = atoi(argv[++i]);
            else if ([arg isEqualToString:@"--threshold"] && i + 1 < argc) threshold = atof(argv[++i]);
            else if ([arg isEqualToString:@"--no-crop"]) doCrop = NO;
            else [pos addObject:arg];
        }

        CIContext *ciContext = [CIContext contextWithOptions:nil];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSSet *validExts = [NSSet setWithObjects:@"jpg", @"jpeg", @"png", @"webp", @"heic", @"tif", @"tiff", nil];

        if (dirMode) {
            NSURL *inFolder = [NSURL fileURLWithPath:dirMode];
            NSURL *destFolder = [NSURL fileURLWithPath:(outDir ?: dirMode)];
            [fm createDirectoryAtURL:destFolder withIntermediateDirectories:YES attributes:nil error:nil];
            NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:inFolder includingPropertiesForKeys:nil options:0 error:nil];
            if (!items) { fprintf(stderr, "Error: could not read directory %s\n", dirMode.UTF8String); return 1; }
            NSArray<NSURL *> *sorted = [items sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
                return [a.lastPathComponent compare:b.lastPathComponent];
            }];
            int failures = 0;
            for (NSURL *file in sorted) {
                NSString *ext = file.pathExtension.lowercaseString;
                NSString *stem = file.URLByDeletingPathExtension.lastPathComponent;
                if (![validExts containsObject:ext] || (!razorOnly && [stem hasSuffix:@"-cutout"])) continue;
                NSURL *outURL = [destFolder URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-cutout.png", stem]];
                NSError *err = nil;
                if (!processFile(file, outURL, paperMode, razorOnly, razorMode, facetsPx, marginPx, threshold, doCrop, ciContext, &err)) {
                    fprintf(stderr, "ERR %s: %s\n", file.lastPathComponent.UTF8String, err.localizedDescription.UTF8String);
                    failures++;
                }
            }
            return failures > 0 ? 1 : 0;
        } else {
            if (pos.count == 0) usage();
            NSURL *inURL = [NSURL fileURLWithPath:pos[0]];
            NSURL *outURL = (pos.count >= 2)
                ? [NSURL fileURLWithPath:pos[1]]
                : [[inURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-cutout.png", inURL.URLByDeletingPathExtension.lastPathComponent]];
            NSError *err = nil;
            if (!processFile(inURL, outURL, paperMode, razorOnly, razorMode, facetsPx, marginPx, threshold, doCrop, ciContext, &err)) {
                fprintf(stderr, "ERR %s\n", err.localizedDescription.UTF8String);
                return 1;
            }
        }
    }
    return 0;
}
