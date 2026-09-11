//  writtem by Chris Rorden on 8/14/12 - distributed under BSD license


#import <Foundation/Foundation.h>
#import "nii_img.h"
#import "nii_colorbar.h"
#include "nifti1.h"
#import "nii_io.h"
#import "nifti1_io_core.h"
#import "nii_ortho.h"
#import "nii_reslice.h"
#include "nii_definetypes.h"
#include "nii_ostu_ml.h"
#import "nii_mosaic.h"
#import "nii_label.h"
#ifdef NII_IMG_RENDER //from nii_definetypes
    #import "nii_render.h"
#endif
#import <MetalKit/MetalKit.h>
#import "NIIMetalRenderer.h"
#import "NIIMetalText.h"
#import "nii_platform.h"
#if TARGET_OS_OSX
    #import <Cocoa/Cocoa.h>
#else
    #import <UIKit/UIKit.h>
#endif

// Display backing scale (Retina factor), used to size Metal-rasterized text.
static CGFloat niiBackingScale(void) {
#if TARGET_OS_OSX
    CGFloat s = [[NSScreen mainScreen] backingScaleFactor];
#else
    CGFloat s = [[UIScreen mainScreen] scale];
#endif
    return (s < 1.0) ? 1.0 : s;
}

@implementation nii_img

// Transient "toast" notifications used the deprecated macOS NSUserNotification
// API. They are macOS-only here; the iPad UIKit layer will surface equivalents
// (e.g. a transient banner) in Phase 4. Guarded so the controller compiles for iOS.
- (void)closePopup
{
#if TARGET_OS_OSX
    [[NSUserNotificationCenter defaultUserNotificationCenter] removeAllDeliveredNotifications];
#endif
}

- (void)notifyOpenFailed;
{
#if TARGET_OS_OSX
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.title = @"Unable to read image";
    notification.informativeText = @"Unknown image format";
    notification.soundName = NULL;
    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
    [NSTimer scheduledTimerWithTimeInterval: 4.0  target:self selector: @selector(closePopup) userInfo:self repeats:NO];
#endif
}

- (void)notifyNotAllVolumesLoaded: (int) loadedVols RawVols: (int) rawVols;
{
#if TARGET_OS_OSX
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.title = [NSString stringWithFormat:@"Loaded %d of %d volumes", loadedVols, rawVols];
    notification.informativeText = @"Reason: The preference 'Only initial volumes' is selected";
    notification.soundName = NULL;
    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
    [NSTimer scheduledTimerWithTimeInterval: 4.5  target:self selector: @selector(closePopup) userInfo:self repeats:NO];
#endif
}

- (void)notifyDICOMwarning;
{
#if TARGET_OS_OSX
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.title = @"DICOM image";
#ifndef STRIP_DCM2NII // /BuildSettings/PreprocessorMacros/STRIP_DCM2NII
    NSDictionary* environ = [[NSProcessInfo processInfo] environment];
    BOOL inSandbox = (nil != [environ objectForKey:@"APP_SANDBOX_CONTAINER_ID"]);
    if (inSandbox)
        notification.informativeText = @"For improved display convert DICOM images to NIfTI (solution: use the free dcm2nii tool)" ;
    else
        notification.informativeText = @"For improved display convert DICOM images to NIfTI (solution: use the 'Import' menu)";
#else
    notification.informativeText = @"For improved display convert DICOM images to NIfTI (solution: use the free dcm2nii tool)" ;
#endif
    notification.soundName = NULL;
    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
    [NSTimer scheduledTimerWithTimeInterval: 4.0  target:self selector: @selector(closePopup) userInfo:self repeats:NO];
#endif
}

-(bool) is2D {
    if ((prefs->displayModeGL == GL_2D_ONLY) || (prefs->displayModeGL == GL_2D_AXIAL)
        || (prefs->displayModeGL == GL_2D_CORONAL) || (prefs->displayModeGL == GL_2D_SAGITTAL)
        )
        return TRUE;
    else
        return FALSE;
}


double getVoxelIntensity(long long vox, FSLIO* fslio) {
    if ((vox < 0) || (vox >= fslio->niftiptr->nvox)) return 0.0;
    if (fslio->niftiptr->datatype == NIFTI_TYPE_RGBA32) {
        // Y = 0.299R + 0.587G + 0.114B
        THIS_UINT8 *inbuf = (THIS_UINT8 *) fslio->niftiptr->data;
        vox = ((vox-1)*4); //saved as RGBA quads (RGBARGBA), indexed from 0
        if ((vox < 0) || (vox >= fslio->niftiptr->nvox)) return 0.0;
        return  roundf ((inbuf[vox]*0.299)+(inbuf[vox+1]*0.587)+(inbuf[vox+2]*0.114));
        //prefs->mouseIntensity = (inbuf[vox]*0.299)+(inbuf[vox+prefs->numVox3D]*0.587)+(inbuf[vox+2*prefs->numVox3D]*0.114);
    } else if ( fslio->niftiptr->datatype == NIFTI_TYPE_UINT8) {
        THIS_UINT8 *inbuf = (THIS_UINT8 *) fslio->niftiptr->data;
        return (inbuf[vox]*fslio->niftiptr->scl_slope)+fslio->niftiptr->scl_inter;
    } else if ( fslio->niftiptr->datatype == NIFTI_TYPE_INT16) {
        THIS_INT16 *inbuf = (THIS_INT16 *) fslio->niftiptr->data;
        return (inbuf[vox]*fslio->niftiptr->scl_slope)+fslio->niftiptr->scl_inter;
    } else {
        SCALED_IMGDATA *inbuf = (SCALED_IMGDATA *) fslio->niftiptr->data;
        return(inbuf[vox]*fslio->niftiptr->scl_slope)+fslio->niftiptr->scl_inter;
    }
}

void getIntensity (NII_PREFS* prefs, FSLIO* fslio) {
    if (prefs->currentVolume > prefs->numVolumes) {
        prefs->mouseIntensity = 0;
        return;
    }
    int slice[3];
    //mm2slice (slice, prefs); //2014
    if ((prefs->voxelDim[1] < 1) || (prefs->voxelDim[2] < 1) || (prefs->voxelDim[3] < 1) ) return;
    mat44 R = prefs->sto_ijk;
    for (int i = 0; i < 3; i++) {
        slice[i] = round( (R.m[i][0]*prefs->mm[1])+(R.m[i][1]*prefs->mm[2])+ (R.m[i][2]*prefs->mm[3])+R.m[i][3] );
        if (slice[i] < 0) slice[i] = 0;
        if (slice[i] >= prefs->voxelDim[i+1]) slice[i] = prefs->voxelDim[i+1]-1;
    }
    long long vox = slice[0] + (slice[1]*prefs->voxelDim[1])+(slice[2]*prefs->voxelDim[1]*prefs->voxelDim[2]);
    //long long nvox = prefs->numVox3D ;
    if (fslio->niftiptr->datatype != NIFTI_TYPE_RGBA32)
        vox = vox + ((prefs->currentVolume-1) * prefs->numVox3D);
    prefs->mouseIntensity = getVoxelIntensity(vox, fslio);
    #ifdef MY_DEBUG //from nii_io.h
    //NSLog(@"nii_img getIntensity for volume %d",prefs->currentVolume);
    #endif
}

void frac2slice (float frac[4], NII_PREFS* prefs) {
    if ((prefs->voxelDim[1] < 1) || (prefs->voxelDim[2] < 1) || (prefs->voxelDim[3] < 1) ) return;
    for (int j = 1; j < 4; j++)
    {
        prefs->tempSliceVox[j] = frac[j]*prefs->voxelDim[j];//convert fraction to voxels
    }
}

void mm2frac (int Xmm, int Ymm, int Zmm, NII_PREFS* prefs)
{
    if ((prefs->voxelDim[1] < 1) || (prefs->voxelDim[2] < 1) || (prefs->voxelDim[3] < 1) ) return;
    mat44 R = prefs->sto_ijk;
    for (int i = 0; i < 3; i++) {
        //-1 as zero based: frac=0.5
        prefs->sliceFrac[i+1] = ( (R.m[i][0]*Xmm)+(R.m[i][1]*Ymm)+ (R.m[i][2]*Zmm)+R.m[i][3] )/(prefs->voxelDim[i+1]-1);

        if ((prefs->sliceFrac[i+1] < 0) || (prefs->sliceFrac[i+1]> 1)) prefs->sliceFrac[i+1] = 0.5;
    }
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"mm2frac mm->frac %d %d %d -> %g %g %g mm",
          Xmm, Ymm, Zmm,
          prefs->sliceFrac[1], prefs->sliceFrac[2], prefs->sliceFrac[3]);
    #endif
    //next for 2D images, otherwise interpolation can make them appear washed out
    if (prefs->voxelDim[1] == 1) prefs->sliceFrac[1] = 0.5;
    if (prefs->voxelDim[2] == 1) prefs->sliceFrac[2] = 0.5;
    if (prefs->voxelDim[3] == 1) prefs->sliceFrac[3] = 0.5;
}

void frac2mm (float frac[4], NII_PREFS* prefs, bool sliceCenter)
{
    if ((prefs->voxelDim[1] < 1) || (prefs->voxelDim[2] < 1) || (prefs->voxelDim[3] < 1) ) return;
    //if (prefs->viewRadiological) frac[1] = 1.0 - frac[1];
    if (sliceCenter) {
        for (int i = 1; i < 4; i++) {
            float hlf = 1.0/((double)prefs->voxelDim[i] * 2.0) ;
            if (frac[i] < hlf)
                frac[i] = hlf;
            else if (frac[i] > (1.0- hlf))
                frac[i] = 1.0 - hlf;
            else {
                float hlf2 = hlf * 2;
                frac[i] = (trunc(frac[i]/hlf2)* hlf2) + hlf;
            }
        }
    }
    float Vox[4];
    for (int j = 1; j < 4; j++) { //convert fraction to voxels
        //-1 as frac=0.5 voxelDim=9 is voxel 4 in zero-indexcoordinates
        Vox[j] = frac[j]*(prefs->voxelDim[j]-1.0);
        prefs->sliceFrac[j] = frac[j];
    }
    mat44 R = prefs->sto_xyz;
    for (int i = 0; i < 3; i++) {
        prefs->mm[i+1] = round( (R.m[i][0]*Vox[1])+(R.m[i][1]*Vox[2])+ (R.m[i][2]*Vox[3])+R.m[i][3] );
    }
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"frac2mm frac->vox->mm %g %g %g -> %g %g %g -> %g %g %g mm",
          prefs->sliceFrac[1], prefs->sliceFrac[2], prefs->sliceFrac[3],
          Vox[1], Vox[2], Vox[3],
          prefs->mm[1], prefs->mm[2], prefs->mm[3]);
    #endif
}

-(bool) changeXYZvoxel: (int) x Y: (int) y Z: (int) z {
    if ((prefs->voxelDim[1] < 1) || (prefs->voxelDim[2] < 1) || (prefs->voxelDim[3] < 1) ) return FALSE;
    float frac[4];
    if (prefs->viewRadiological)
        frac[1] = ((prefs->sliceFrac[1]*(float)prefs->voxelDim[1])-x)/(float)prefs->voxelDim[1];
    else
        frac[1] = ((prefs->sliceFrac[1]*(float)prefs->voxelDim[1])+x)/(float)prefs->voxelDim[1];
    frac[2] = ((prefs->sliceFrac[2]*(float)prefs->voxelDim[2])+y)/(float)prefs->voxelDim[2];
    frac[3] = ((prefs->sliceFrac[3]*(float)prefs->voxelDim[3])+z)/(float)prefs->voxelDim[3];
    /*for (int i = 1; i < 4; i++) {
        float hlf = halfSlice(prefs->voxelDim[i]);
        if (frac[i] < hlf)
            frac[i] = hlf;
        else if (frac[i] > (1.0- hlf))
            frac[i] = 1.0 - hlf;
        else {
            float hlf2 = hlf * 2;
            frac[i] = (trunc(frac[i]/hlf2)* hlf2) + hlf;
        }
    }*/
    frac2mm (frac, prefs, true); //arrows
    prefs->force_refreshGL = TRUE;
    return TRUE;
}

-(bool) setXYZmm: (float) x Y: (float) y Z: (float) z {
    if ((prefs->mm[1] == x) && (prefs->mm[2] == y) && (prefs->mm[3] == z)) return FALSE;
    //NSLog(@" move from %fx%fx%f to %fx%fx%f", prefs->mm[1],prefs->mm[2],prefs->mm[3],x, y, z);
    mm2frac (x, y, z,  prefs);
    //it is possible that the desired mm were outside the range of our volume....
    float frac[4];
    frac[1] = prefs->sliceFrac[1];
    frac[2] = prefs->sliceFrac[2];
    frac[3] = prefs->sliceFrac[3];
    frac2mm (frac, prefs,true); //yoke
    prefs->force_refreshGL = TRUE;
    return TRUE;
}

-(bool) isTimelineUpdateNeeded {
    if (prefs->busyGL == TRUE) return FALSE;
    return prefs->updatedTimeline;
}

-(GraphStruct) getTimeline {
    GraphStruct graph;
    graph.data = NULL; // so early returns (no graph) leave a safe-to-free pointer
    prefs->updatedTimeline = false;
    graph.timepoints = prefs->numVolumes;
    graph.selectedTimepoint = prefs->currentVolume;
    if ((prefs->voxelDim[1] < 1) || (prefs->voxelDim[2] < 1) || (prefs->voxelDim[3] < 1) ) graph.timepoints = 0;
    graph.lines = 1;
    graph.verticalScale =fslio->niftiptr->pixdim[4];
    int slice[3];
    //slice[0] = 0; slice[1] = 0; slice[2] = 0; //prevents compiler warning - adjusted in mm2slice
    //mm2slice (slice, prefs); //2014
    //if ((prefs->voxelDim[1] < 1) || (prefs->voxelDim[2] < 1) || (prefs->voxelDim[3] < 1) ) return;
    mat44 R = prefs->sto_ijk;
    for (int i = 0; i < 3; i++) {
        slice[i] = round( (R.m[i][0]*prefs->mm[1])+(R.m[i][1]*prefs->mm[2])+ (R.m[i][2]*prefs->mm[3])+R.m[i][3] );
        if (slice[i] < 0) slice[i] = 0;
        if (slice[i] >= prefs->voxelDim[i+1]) slice[i] = prefs->voxelDim[i+1]-1;
    }
    long long vox = slice[0] + (slice[1]*prefs->voxelDim[1])+(slice[2]*prefs->voxelDim[1]*prefs->voxelDim[2]);
    long long nvox = prefs->numVox3D ; //prefs->voxelDim[1]*prefs->voxelDim[2]*prefs->voxelDim[3];
    if ((vox < 0) || (vox >= nvox) ) graph.timepoints = 0;
    if (graph.timepoints < 2) return graph; //no graph
    graph.data = (float *) malloc( prefs->numVolumes*sizeof(float));
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"nii_img 7 malloc size %ld", prefs->numVolumes*sizeof(float));
    #endif
    //load data
    //NSLog(@" %d %d %d  %d %d %d", prefs->voxelDim[1],prefs->voxelDim[2],prefs->voxelDim[3], fslio->niftiptr->dim[1],fslio->niftiptr->dim[2],fslio->niftiptr->dim[3]);
    if ((prefs->busyGL) || (fslio->niftiptr->dim[1] != prefs->voxelDim[1])  || (fslio->niftiptr->dim[2] != prefs->voxelDim[2]) || (fslio->niftiptr->dim[3] != prefs->voxelDim[3])){
        prefs->updatedTimeline = TRUE; //check back when the main process is not busy
        graph.timepoints = 1;
        return graph;
    }
    prefs->busyGL = TRUE;
    //slice[n] has i,j,k coordinate of voxel
    float scale =fslio->niftiptr->scl_slope;
    float inter =fslio->niftiptr->scl_inter;
    if (fslio->niftiptr->datatype == NIFTI_TYPE_RGBA32) {
        NSLog(@"Timelines not (yet) supported for RGBA data.");
        for (int i = 0; i < prefs->numVolumes; i++)
            graph.data[i] = i;
    } else if ( fslio->niftiptr->datatype == NIFTI_TYPE_UINT8) {
        THIS_UINT8 *inbuf = (THIS_UINT8 *) fslio->niftiptr->data;
        for (int vol = 0; vol < prefs->numVolumes; vol++) {
            graph.data[vol] = (inbuf[vox]*scale)+inter;
            vox += nvox;
        }
    } else if ( fslio->niftiptr->datatype == NIFTI_TYPE_INT16) {
        THIS_INT16 *inbuf = (THIS_INT16 *) fslio->niftiptr->data;
        for (int vol = 0; vol < prefs->numVolumes; vol++) {
            graph.data[vol] =  (inbuf[vox]*scale)+inter;
            vox = vox + nvox;
        }
    } else {
        SCALED_IMGDATA *inbuf = (SCALED_IMGDATA *) fslio->niftiptr->data;
        for (int vol = 0; vol < prefs->numVolumes; vol++) {
            graph.data[vol] = (inbuf[vox]*scale)+inter;
            vox += nvox;
        }
    }
    prefs->busyGL = FALSE;
    return graph;
}

//int ret = convertBufferToScaled(&outbuf[0], fslio->niftiptr->data, (long)(fslio->niftiptr->nvox), slope, inter, fslio->niftiptr->datatype);
//nii_unify_datatype
int xx(FSLIO* fslio) {


        if (fslio->niftiptr->scl_slope == 0) { //nonsense value - fix the header!
            fslio->niftiptr->scl_slope = 1.0;
            fslio->niftiptr->scl_inter = 0.0;
        }
    //fslio->niftiptr->
    size_t len = fslio->niftiptr->nvox;
    void *inbuf = fslio->niftiptr->data;

    int ret = 0;
    if (NIFTI_TYPE_UINT8)
        for (int i=0; i<len; i++)
            if (((THIS_UINT8 *)(inbuf)+i) != 0)
                ret += 1;

    return ret;

}
int  convertBufferToScaled(SCALED_IMGDATA *outbuf, void *inbuf, long len, float slope, float inter, int nifti_datatype ) {
//adapted from fslio.c "convertBufferToScaledDouble" library that was placed in the public domain
    long i;
    switch(nifti_datatype) {
        case NIFTI_TYPE_UINT8:
            for (i=0; i<len; i++)
                outbuf[i] = (SCALED_IMGDATA) ( *((THIS_UINT8 *)(inbuf)+i) * slope + inter);
            break;
        case NIFTI_TYPE_INT8:
            for (i=0; i<len; i++)
                outbuf[i] = (SCALED_IMGDATA) ( *((THIS_INT8 *)(inbuf)+i) * slope + inter);
            break;
        case NIFTI_TYPE_UINT16:
            for (i=0; i<len; i++)
                outbuf[i] = (SCALED_IMGDATA) ( *((THIS_UINT16 *)(inbuf)+i) * slope + inter);
            break;
        case NIFTI_TYPE_INT16:
            for (i=0; i<len; i++)
                outbuf[i] = (SCALED_IMGDATA) ( *((THIS_INT16 *)(inbuf)+i) * slope + inter);
            break;
        case NIFTI_TYPE_UINT64:
            for (i=0; i<len; i++)
                outbuf[i] = (SCALED_IMGDATA) ( *((THIS_UINT64 *)(inbuf)+i) * slope + inter);
            break;
        case NIFTI_TYPE_INT64:
            for (i=0; i<len; i++)
                outbuf[i] = (SCALED_IMGDATA) ( *((THIS_INT64 *)(inbuf)+i) * slope + inter);
            break;
        case NIFTI_TYPE_UINT32:
            for (i=0; i<len; i++)
                outbuf[i] = (SCALED_IMGDATA) ( *((THIS_UINT32 *)(inbuf)+i) * slope + inter);
            break;
        case NIFTI_TYPE_INT32:
            for (i=0; i<len; i++)
                outbuf[i] = (SCALED_IMGDATA) ( *((THIS_INT32 *)(inbuf)+i) * slope + inter);
            break;
        case NIFTI_TYPE_FLOAT32:
            for (i=0; i<len; i++)
                outbuf[i] = (SCALED_IMGDATA) ( *((THIS_FLOAT32 *)(inbuf)+i) * slope + inter);
            break;
        case NIFTI_TYPE_FLOAT64:
            if ((slope == 1.0f) && (inter == 0.0f)) { //NIFTI stores inter/slope as 32-bit floats, so not really appropriate for 64 bit
                for (i=0; i<len; i++)
                    outbuf[i] = (SCALED_IMGDATA) ( *((THIS_FLOAT64 *)(inbuf)+i) );

            } else {
                for (i=0; i<len; i++)
                    outbuf[i] = (SCALED_IMGDATA) ( *((THIS_FLOAT64 *)(inbuf)+i) * slope + inter);
            }
            break;
        case NIFTI_TYPE_FLOAT128:
        case NIFTI_TYPE_COMPLEX128:
        case NIFTI_TYPE_COMPLEX256:
        case NIFTI_TYPE_COMPLEX64:
        default:
            fprintf(stderr, "\nWarning, cannot support %d yet.\n",nifti_datatype);
            return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}

bool isPlanarImg(FSLIO* fslio) {
//determine if RGB image is PACKED TRIPLETS (RGBRGBRGB...) or planar (RR..RGG..GBB..B)
//assumes strong correlation between voxel and neighbor on next line
    if (fslio->niftiptr->dim[2] < 2) return false; //requires at least 2 rows of data
    int incPlanar = fslio->niftiptr->dim[1]; //increment next row of PLANAR image
    int incPacked = fslio->niftiptr->dim[1] * 3; //increment next row of PACKED image
    int byteSlice = incPacked * fslio->niftiptr->dim[2]; //bytes per 3D slice of RGB data
    double dxPlanar = 0.0;//difference in PLANAR
    double dxPacked = 0.0;//difference in PACKED
    int pos = (fslio->niftiptr->dim[3]/2) * byteSlice; //offset to middle slice for 3D data
    THIS_UINT8 *rawRGB = (THIS_UINT8 *) fslio->niftiptr->data;
    int posEnd = pos + byteSlice - incPacked;
    while (pos < posEnd) {
        dxPlanar += abs(rawRGB[pos]-rawRGB[pos+incPlanar]);
        dxPacked += abs(rawRGB[pos]-rawRGB[pos+incPacked]);
        pos++;
    }
    return (dxPlanar < dxPacked);
} //isPlanarImg()

int convertRGB2RGBA(FSLIO* fslio)
//convert 24-bit red-green-blue to OpenGL-native red-green-blue-alpha components
//WARNING Analyze RGB format is planar RRRR...RGGGG....GBBBB...B we will convert to RGBARGBARGBARGBA....
{
    int nx = fslio->niftiptr->dim[1];
    int ny = fslio->niftiptr->dim[2];
    int nz = fslio->niftiptr->dim[3];
    //NSLog(@"%d\n", fslio->niftiptr->intent_code);
    int o = 0; //output
    size_t sizebytes = fslio->niftiptr->nvox*sizeof(uint32_t);
    THIS_UINT8 *outbuf = (THIS_UINT8 *) malloc(sizebytes);
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"nii_img 2 malloc size %ld", sizebytes);
    #endif
    THIS_UINT8 *rawRGB = (THIS_UINT8 *) fslio->niftiptr->data;
    int nvol = 1;
    for (int dim = 4; dim < 8; dim++)
        if (fslio->niftiptr->dim[dim] > 1)
            nvol = nvol * fslio->niftiptr->dim[dim];
    //NSLog(@"true %g", correlRGB(fslio, true));
    //NSLog(@"false %g", correlRGB(fslio, false));
    //NSLog(@"isPlanar %d", isPlanarImg(fslio));
    //bool isPlanar  = ([[NSApp currentEvent] modifierFlags] & NSAlternateKeyMask);
    bool isPlanar  = isPlanarImg(fslio);
    if (!isPlanar) { //input is packed triplets RGBRGB... output RGBARGBA...
        int i = 0; //input
        int nxyzv = nx*ny*nz*nvol; //number of voxels in total
        for (int xyzv = 0; xyzv < nxyzv; xyzv++) { //for all voxels
            outbuf[o++] = rawRGB[i++]; //red
            outbuf[o++] = rawRGB[i++]; //gree
            outbuf[o++] = rawRGB[i++]; //blue
            outbuf[o++] = rawRGB[i-2] /2;//green best estimate for alpha
        } //xyzv: all voxels
    } else { //input is planar RRR...GGG...BBBB... output RGBARGBA...
        int nxy = nx*ny; //number of voxels in a plane
        int nxy2 = nxy * 2;
        int iR = 0; //index Red
        int nzv = nz * nvol; //number of volumes times slices per volume
        for (int zv= 0; zv < nzv; zv++) { //for each 2D slice
            int iG = iR + nxy; //index Green
            int iB = iR + nxy2; //index Blue
            for (int xy = 0; xy < nxy; xy++) { //for each voxel in slice (all columns*rows)
                outbuf[o++] = rawRGB[iR++]; //red
                outbuf[o++] = rawRGB[iG++]; //green
                outbuf[o++] = rawRGB[iB++]; //blue
                outbuf[o++] = rawRGB[iG - 1] /2;//green best estimate for alpha
            } //xy: each voxel in slice
            iR += nxy2; //done reading red plane, skip green and blue planes for start of next red plane
        } //zv: total number of 2D slices
    }
    //free(fslio->niftiptr->data);
    //fslio->niftiptr->data = outbuf;
    //int ret = convertBufferToScaled(&outbuf[0], fslio->niftiptr->data, (long)(fslio->niftiptr->nvox), slope, inter, fslio->niftiptr->datatype);
    fslio->niftiptr->datatype =DT_RGBA32;
    fslio->niftiptr->nbyper = 4;
    fslio->niftiptr->scl_slope = 1.0; //image data rescaled
    fslio->niftiptr->scl_inter = 0.0; //image data rescaled
    free(fslio->niftiptr->data);
    fslio->niftiptr->data = outbuf;
    //return EXIT_FAILURE;
    return EXIT_SUCCESS;
}

bool isNaN32( float value ) {
    return ((*(THIS_UINT32*)&value) & 0x7fffffff) > 0x7f800000;
}

//http://www.johndcook.com/IEEE_exceptions_in_cpp.html
void ZeroNaN32 (void *inbuf, size_t len) {
    THIS_FLOAT32  *buf = (THIS_FLOAT32 *) inbuf;
    for (size_t i=0; i<len; i++) {
        if ( isNaN32(buf[i]))
            buf[i] = 0.0;
    }
}

void clipInf32 (void *inbuf, size_t len) {
    THIS_FLOAT32  *buf = (THIS_FLOAT32 *) inbuf;
    bool hasInf = false;
    for (size_t i=0; i<len; i++) {
        if ((buf[i] == INFINITY) || (buf[i] == -INFINITY) ) {
            hasInf = true;
            break;
        }
    }//for each voxel
    if (!hasInf) return;
    //2nd pass - find largest and smallest values that are NOT infinity!
    THIS_FLOAT32 nmin = INFINITY;
    THIS_FLOAT32 nmax = -INFINITY;
    for (size_t i=0; i<len; i++) {
        if ((buf[i] > nmax) && (buf[i] < INFINITY)) nmax = buf[i];
        if ((buf[i] < nmin) && (buf[i] > -INFINITY)) nmin = buf[i];
    }//for each voxel
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"Removing inifinity values (finite data range %f..%f)",nmin,nmax);
    #endif
    if (nmax == nmin) { //all numerical values identical, e.g. region is 1 masked by NaNs
        THIS_FLOAT32 v = nmax;
        nmax = v - 1;
        nmin = v + 1;
    }
    if (nmin == INFINITY) nmin = 0; //ONLY occurs if all voxels are INFINITY
    if (nmax == -INFINITY) nmax = 0; //ONLY occurs if all voxels are -INFINITY

    for (size_t i=0; i<len; i++) {
        if (buf[i] == INFINITY) buf[i] = nmax;
        if (buf[i] == -INFINITY) buf[i] = nmin;
    }//for each voxel
}

#define I64(f) (*(long long int *)&f)
static bool isNaN64 (double value) {
    unsigned long long int jvalue = (I64(value) &
                                     ~0x8000000000000000uLL);
    return (jvalue > 0x7ff0000000000000uLL);
}

void ZeroNaN64 (void *inbuf, size_t len) {
    THIS_FLOAT64  *buf = (THIS_FLOAT64 *) inbuf;
    for (size_t i=0; i<len; i++) {
        if ( isNaN64(buf[i]))
            buf[i] = 0.0;
    }
}

void clipInf64 (void *inbuf, size_t len) {
    THIS_FLOAT64  *buf = (THIS_FLOAT64 *) inbuf;
    bool hasInf = false;
    for (size_t i=0; i<len; i++) {
        if ((buf[i] == INFINITY) || (buf[i] == -INFINITY) ) {
            hasInf = true;
            break;
        }
    }//for each voxel
    if (!hasInf) return;
    //2nd pass - find largest and smallest values that are NOT infinity!
    THIS_FLOAT64 nmin = INFINITY;
    THIS_FLOAT64 nmax = -INFINITY;
    for (size_t i=0; i<len; i++) {
        if ((buf[i] > nmax) && (buf[i] < INFINITY)) nmax = buf[i];
        if ((buf[i] < nmin) && (buf[i] > -INFINITY)) nmin = buf[i];
    }//for each voxel
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"Removing inifinity values (finite data range %f..%f)",nmin,nmax);
    #endif
    if (nmax == nmin) { //all numerical values identical, e.g. region is 1 masked by NaNs
        THIS_FLOAT64 v = nmax;
        nmax = v - 1;
        nmin = v + 1;
    }
    if (nmin == INFINITY) nmin = 0; //ONLY occurs if all voxels are INFINITY
    if (nmax == -INFINITY) nmax = 0; //ONLY occurs if all voxels are -INFINITY
    for (size_t i=0; i<len; i++) {
        if (buf[i] == INFINITY) buf[i] = nmax;
        if (buf[i] == -INFINITY) buf[i] = nmin;
    }//for each voxel
}

int nii_unify_datatype(FSLIO* fslio)
//this converts all unusual datatypes to SCALED_IMGDATA type (nii_definetypes)
// common supported datatypes are not changed.
{
    if (fslio->niftiptr->scl_slope == 0) { //nonsense value - fix the header!
        fslio->niftiptr->scl_slope = 1.0;
        fslio->niftiptr->scl_inter = 0.0;
    }


    if ( fslio->niftiptr->datatype == NIFTI_TYPE_FLOAT32) {
        ZeroNaN32(fslio->niftiptr->data, fslio->niftiptr->nvox);
        clipInf32(fslio->niftiptr->data, fslio->niftiptr->nvox);
    }
    if ( fslio->niftiptr->datatype == NIFTI_TYPE_FLOAT64) {

        ZeroNaN64(fslio->niftiptr->data, fslio->niftiptr->nvox);
        clipInf64(fslio->niftiptr->data, fslio->niftiptr->nvox);
    }
    if (fslio==NULL)  {
        printf("nii_unify: Null pointer passed for FSLIO");
        return EXIT_FAILURE;
    }
    /*if ((fslio->niftiptr->dim[0] <= 0) || (fslio->niftiptr->dim[0] > 4)) {
        printf("nii_unify: Incorrect dataset dimension, 1-4D needed, image reports %d\n", fslio->niftiptr->dim[0]);
        return EXIT_FAILURE;
    }*/
    if (fslio->niftiptr->nvox < 1) {
        printf("nii_unify: voxels not loaded!");
        return EXIT_FAILURE;
    }

//don't convert a format that is natively supported...
    if ( fslio->niftiptr->datatype == DT_RGB24) return convertRGB2RGBA(fslio); //24-bit RGBA must convert to 32-bit RGBA
    if ( fslio->niftiptr->datatype == DT_RGBA32) return EXIT_SUCCESS; //32-bit RGBA bit format is supported!
    if ( fslio->niftiptr->datatype == NIFTI_TYPE_UINT8) return EXIT_SUCCESS; //unsigned 8 bit format is supported!
    if ( fslio->niftiptr->datatype ==NIFTI_TYPE_INT16) return EXIT_SUCCESS;//signed 16 bit format is supported!
    //rescale image
    float slope = fslio->niftiptr->scl_slope;
    float inter = fslio->niftiptr->scl_inter;
    if ((fslio->niftiptr->datatype == SCALED_IMGDATA_TYPE) && (slope == 1.0f) && (inter == 0.0f)) return EXIT_SUCCESS;//float 32 bit format is supported!

    //if ((fslio->niftiptr->datatype == NIFTI_TYPE_FLOAT32) && (slope == 1.0f) && (inter == 0.0f)) return EXIT_SUCCESS;//float 32 bit format is supported!
    //convertBufferToScaled SCALED_IMGDATA_TYPE        NIFTI_TYPE_FLOAT32
    if (fslio->niftiptr->datatype == SCALED_IMGDATA_TYPE) {
        //special case: image format does not change, simply rescale data
        SCALED_IMGDATA *buf = (SCALED_IMGDATA *)fslio->niftiptr->data;
        for (int i=0; i<fslio->niftiptr->nvox; i++)
            buf[i] = buf[i] * slope + inter;
        fslio->niftiptr->scl_slope = 1.0; //image data rescaled
        fslio->niftiptr->scl_inter = 0.0; //image data rescaled
        return EXIT_SUCCESS;
    }
    size_t sizebytes = fslio->niftiptr->nvox*sizeof(SCALED_IMGDATA);
    SCALED_IMGDATA *outbuf = (SCALED_IMGDATA *) malloc(sizebytes);
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"nii_img 3 malloc size %ld",sizebytes);
    #endif
    int ret = convertBufferToScaled(&outbuf[0], fslio->niftiptr->data, (long)(fslio->niftiptr->nvox), slope, inter, fslio->niftiptr->datatype);
    if (ret != EXIT_SUCCESS) {
        free(fslio->niftiptr->data);
        fslio->niftiptr->data = outbuf;
        NSLog(@"convertBufferToScaled failed");
        return EXIT_FAILURE;
    }
    if (sizeof(SCALED_IMGDATA) == 4) {
        fslio->niftiptr->datatype =NIFTI_TYPE_FLOAT32;
        fslio->niftiptr->nbyper = 4;
    } else if (sizeof(SCALED_IMGDATA) == 8) {
        fslio->niftiptr->datatype =NIFTI_TYPE_FLOAT64;
        fslio->niftiptr->nbyper = 8;
    } else {
        printf("compiled with invalid SCALED_IMGDATA");
    }
    fslio->niftiptr->scl_slope = 1.0; //image data rescaled
    fslio->niftiptr->scl_inter = 0.0; //image data rescaled
    free(fslio->niftiptr->data);
    fslio->niftiptr->data = outbuf;
    return EXIT_SUCCESS;
}

const double kPercentile = 0.01; //proportion of voxels counted as outliers, e.g. if 0.05, then suggested contrast scales from darkest 5% to brightest 5%
//const long kBins = 1024; //we will sort the full image range into this many historgram bins...
const long kSampleRate = 7; //we do not have to test every voxel to detect typical intensity distribution - if 1 every voxel is tested, if 5 every 5th voxel is tested...

int nii_findrangefloat (FSLIO* fslio, NII_PREFS* prefs) {
    //find range for floating point data (default precision)
    //long len = fslio->niftiptr->nvox; //ALL VOLUMES
    long len = prefs->numVox3D; //ONLY FIRST VOLUME!
    SCALED_IMGDATA *num_list = (SCALED_IMGDATA *)fslio->niftiptr->data;
    if ( len < 1) return EXIT_FAILURE;
    SCALED_IMGDATA min = num_list[0];
    SCALED_IMGDATA max = min;
    for (long j = 0; j < len; j++) {
        if (num_list[j] < min) min = num_list[j];
        if (num_list[j] > max) max = num_list[j];
    }
    prefs->fullMin = (min* fslio->niftiptr->scl_slope)+fslio->niftiptr->scl_inter;
    prefs->fullMax = (max* fslio->niftiptr->scl_slope)+fslio->niftiptr->scl_inter;
    if (prefs->fullMin >= prefs->fullMax) { //no variability in data
        prefs->nearMin = prefs->fullMin;
        prefs->nearMax = prefs->fullMax;
        return EXIT_SUCCESS;
    }
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"nii_findrangefloat slope=%f intercept=%f range=%f..%f",fslio->niftiptr->scl_slope,fslio->niftiptr->scl_inter,prefs->fullMin, prefs->fullMax);
    #endif
    //long bins[kBins];
    for (long k = 0; k < MAX_HISTO_BINS; k++) prefs->histo[k] = 0; //XCode 4.0 Variable length arrays not initialized
    min = prefs->fullMin;
    //SCALED_IMGDATA slope = (kBins-1)/(prefs->fullMax - prefs->fullMin);
    double slope = (MAX_HISTO_BINS-1)/(prefs->fullMax - prefs->fullMin);
    int pos;
    for (long j = 0; j < len; j+=kSampleRate) {
        pos = round((num_list[j]-min)*slope);
        if ((pos >=0) && (pos < MAX_HISTO_BINS)) //only needed if extreme values, very little penalty
            prefs->histo[pos]++;
    }
    long percentile = round (((len+kSampleRate-1) / kSampleRate)  *kPercentile); //how many voxels eqaul desired %
    //next find darkest 5th percent
    long samples = 0;
    pos = 0;
    do {
        samples += prefs->histo[pos];
        pos++;
    } while (samples < percentile);
    prefs->nearMin = ((pos-1)/slope)+min;
    //find brightest 5th percent
    samples = 0;
    pos = MAX_HISTO_BINS-1;
    do {
        samples += prefs->histo[pos];
        pos--;
    } while (samples < percentile);
    prefs->nearMax = ((pos+1)/slope)+min;
    return EXIT_SUCCESS;
}

int nii_findrange8ui (FSLIO* fslio, NII_PREFS* prefs)
//find range for 8 bit unsigned integers
{
    //long len = fslio->niftiptr->nvox;//ALL VOLUMES
    long len = prefs->numVox3D; //ONLY FIRST VOLUME!
    if ( len < 1) return EXIT_FAILURE;
    THIS_UINT8 *num_list = (THIS_UINT8 *) fslio->niftiptr->data;
    THIS_UINT8 min = num_list[0];
    THIS_UINT8 max = min;
    for (long j = 0; j < len; j++) {
        if (num_list[j] < min) min = num_list[j];
        if (num_list[j] > max) max = num_list[j];
    }
    prefs->fullMin = (min* fslio->niftiptr->scl_slope)+fslio->niftiptr->scl_inter;
    prefs->fullMax = (max* fslio->niftiptr->scl_slope)+fslio->niftiptr->scl_inter;
    if (prefs->fullMin >= prefs->fullMax) { //no variability in data
        prefs->nearMin = prefs->fullMin;
        prefs->nearMax = prefs->fullMax;
        return EXIT_SUCCESS;
    }
    const long kBins8 = 256; //for 8 bit data, 256 bins provide complete coverage
    long bins[kBins8];
    for (long k = 0; k < kBins8; k++) bins[k] = 0; //XCode 4.0 variable length arrays not initialized
    int pos;
    for (long j = 0; j < len; j+=kSampleRate)
        bins[ num_list[j] ]++;
    long percentile = round (((len+kSampleRate-1) / kSampleRate)  *kPercentile); //how many voxels eqaul desired %
    //next find darkest 5th percent
    long samples = 0;
    pos = 0;
    do {
        samples += bins[pos];
        pos++;
    } while (samples < percentile);
    //prefs->nearMin = (pos-1);
    prefs->nearMin = ((pos-1)* fslio->niftiptr->scl_slope)+fslio->niftiptr->scl_inter;
    //find brightest 5th percent
    samples = 0;
    pos = kBins8-1;
    do {
        samples += bins[pos];
        //printf("bin %d has %ld\n",pos,bins[pos]);
        pos--;
    } while (samples < percentile);
    prefs->nearMax = ((pos+1)* fslio->niftiptr->scl_slope)+fslio->niftiptr->scl_inter;
    float histoScale = float(kBins8) / float(MAX_HISTO_BINS);
    int kMax = kBins8-1;
    for (long j = 0; j < MAX_HISTO_BINS; j++) {
        pos =  round( (float)j * histoScale);
        pos = MAX(0, pos);
        pos = MIN(pos, kMax);
        prefs->histo[j] = bins[pos];
    }
    return EXIT_SUCCESS;
}

int nii_findrange16i (FSLIO* fslio, NII_PREFS* prefs)
//find range for 16 bit signed integers
{
    //long len = fslio->niftiptr->nvox;//ALL VOLUMES
    long len = prefs->numVox3D; //ONLY FIRST VOLUME!
    if ( len < 1) return EXIT_FAILURE;
    THIS_INT16 *num_list = (THIS_INT16 *) fslio->niftiptr->data;
    long min = num_list[0];
    long max = min;
    for (long j = 0; j < len; j++) {
        if (num_list[j] < min) min = num_list[j];
        if (num_list[j] > max) max = num_list[j];
    }
    prefs->fullMin = (min* fslio->niftiptr->scl_slope)+fslio->niftiptr->scl_inter;
    prefs->fullMax = (max* fslio->niftiptr->scl_slope)+fslio->niftiptr->scl_inter;
    if (min >= max) { //no variability in data
        prefs->nearMin = prefs->fullMin;
        prefs->nearMax = prefs->fullMax;
        return EXIT_SUCCESS;
    }
    for (long k = 0; k < MAX_HISTO_BINS; k++) prefs->histo[k] = 0; //XCode 4.0 variable length arrays not initialized
    float range = (max-min);
    float slope = (MAX_HISTO_BINS-1)/range;
    int pos;
    long long islope = 1 << 16;//source is 16 bit, we are using 64bit longs...
    islope = round(islope * slope);
    for (long j = 0; j < len; j+=kSampleRate) {
        //pos = round((num_list[j]-min)*slope); // <- OPTIMIZE this line is expensive - compute as integer or use look up table?
        pos = int( ((num_list[j]-min)*islope) >> 16); // <- integer multiplication dramatically faster on Intel i5 CPU (x3 for entire function)
        prefs->histo[ pos]++;
    }
    long percentile = round (((len+kSampleRate-1) / kSampleRate)  *kPercentile); //how many voxels eqaul desired %
    //next find darkest 5th percent
    long samples = 0;
    pos = 0;
    do {
        samples += prefs->histo[pos];
        pos++;
    } while (samples < percentile);
    prefs->nearMin = ((pos-1)/slope)+min;
    prefs->nearMin = (prefs->nearMin * fslio->niftiptr->scl_slope)+fslio->niftiptr->scl_inter;
    //find brightest 5th percent
    samples = 0;
    pos = MAX_HISTO_BINS-1;
    do {
        samples += prefs->histo[pos];
        pos--;
    } while (samples < percentile);
    prefs->nearMax = ((pos+1)/slope)+min;
    prefs->nearMax = (prefs->nearMax * fslio->niftiptr->scl_slope)+fslio->niftiptr->scl_inter;
    return EXIT_SUCCESS;
}

int nii_findrange (FSLIO* fslio, NII_PREFS* prefs) {
    //finds brightest and darkest voxels - both maximum extremes (fullMin/fullMax) and disregarding outliers (nearMin,nearMax)
    int ret = EXIT_FAILURE;
    if ((fslio->niftiptr->intent_code == NIFTI_INTENT_LABEL) && (( fslio->niftiptr->datatype == NIFTI_TYPE_UINT8) ||  ( fslio->niftiptr->datatype == NIFTI_TYPE_INT16))  ){
        prefs->fullMin = 0;
        prefs->fullMax = 100;
        prefs->nearMin = prefs->fullMin;
        prefs->nearMax = prefs->fullMax;
        prefs->viewMin = prefs->fullMin;
        prefs->viewMax = prefs->fullMax;
        ret = EXIT_SUCCESS;
    } else if (fslio->niftiptr->datatype == NIFTI_TYPE_RGBA32) {
        prefs->fullMin = 0;
        prefs->fullMax = 255;
        prefs->nearMin = prefs->fullMin;
        prefs->nearMax = prefs->fullMax;
        if ((fslio->niftiptr->cal_min < fslio->niftiptr->cal_max) && ((fslio->niftiptr->cal_max - fslio->niftiptr->cal_min) > 2 )) {
            prefs->nearMin = fslio->niftiptr->cal_min;
            prefs->nearMax = fslio->niftiptr->cal_max;
        }
        prefs->viewMin = prefs->nearMin;
        prefs->viewMax = prefs->nearMax;
        ret = EXIT_SUCCESS;
    } else if ( fslio->niftiptr->datatype == NIFTI_TYPE_UINT8)
        ret= nii_findrange8ui(fslio, prefs);
    else if ( fslio->niftiptr->datatype == NIFTI_TYPE_INT16)
        ret= nii_findrange16i(fslio, prefs);
    else
        ret= nii_findrangefloat(fslio, prefs);
    if ((fslio->niftiptr->datatype != NIFTI_TYPE_RGBA32) && (fslio->niftiptr->intent_code != NIFTI_INTENT_LABEL) && (fslio->niftiptr->cal_min >= prefs->fullMin) && (fslio->niftiptr->cal_max <= prefs->fullMax)
        && (fslio->niftiptr->cal_min < fslio->niftiptr->cal_max)
        ) {
        #ifdef MY_DEBUG //from nii_io.h
        NSLog(@"Using header intensity calibration %g..%g",fslio->niftiptr->cal_min,fslio->niftiptr->cal_max);
        #endif
        prefs->nearMin = fslio->niftiptr->cal_min; //use values suggested in header
        prefs->nearMax = fslio->niftiptr->cal_max;
    }
    //initially provide the user with image contrast using the image intensity range that ignores outliers...
    if (prefs->nearMin != prefs->nearMax) {
        prefs->viewMin = prefs->nearMin;
        prefs->viewMax = prefs->nearMax;
    } else {
        prefs->viewMin = prefs->fullMin;
        prefs->viewMax = prefs->fullMax;
    }
    if ((prefs->viewMin >= -4096) && (prefs->viewMin <= -1000) && (prefs->viewMax >= 1000) && (prefs->viewMax <= 4096)) { //autoscale CT scans for brain
        prefs->viewMin = -10;
        prefs->viewMax = 100;
    }
    #ifdef MY_DEBUG //from nii_io.h
        printf("full intensity range %f..%f\n",prefs->fullMin ,prefs->fullMax);
        printf("range excluding outliers %f..%f\n",prefs->nearMin ,prefs->nearMax);
    #endif
    return ret;
}

uint32_t makeRGBA (THIS_UINT8 r, THIS_UINT8 g, THIS_UINT8 b, THIS_UINT8 a)
{
    return (r << 0)+ (g << 8) + (b << 16) + (a << 24);
}

uint32_t lerprgb (uint32_t lo, uint32_t hi, int loindex, int hiindex, int tarindex)
//linear interpolation for RGB color between lo and hi
{
    float frac = float(tarindex-loindex)/(hiindex-loindex);
    uint32_t ret;
    THIS_UINT8* plo = (THIS_UINT8*)&lo;
    THIS_UINT8* phi = (THIS_UINT8*)&hi;
    THIS_UINT8* pret = (THIS_UINT8*)&ret;
    for (int i = 0; i < 4; i++)
        pret[i] = (plo[i]+ frac*(phi[i]- plo[i]) ); //linear interpolations
    return ret;
}



/*int filllut(uint32_t lo, uint32_t hi, int loIndex, int hiIndex, uint32_t* lut) {
    for (int i = loIndex; i < hiIndex; i++)
        lut[i] = lerprgb(lo, hi, loIndex, hiIndex,i);
    return hiIndex;
}*/

struct RGBAnode
{
    uint32_t rgba;
    int   intensity;
} ;

struct RGBAnode makeRGBAnode (THIS_UINT8 r, THIS_UINT8 g, THIS_UINT8 b, THIS_UINT8 a, int inten)
{
    struct RGBAnode ret;
    ret.rgba =  (r << 0)+ (g << 8) + (b << 16) + (a << 24);
    ret.intensity = inten;
    return ret;
}

void filllut(struct RGBAnode loNode, struct RGBAnode hiNode, uint32_t* lut) {
    int mn = (loNode.intensity >= 0) ? loNode.intensity : 0;
    int mx = (hiNode.intensity <= 256) ? hiNode.intensity : 256;
    for (int i = mn; i < mx; i++)
        lut[i] = lerprgb(loNode.rgba, hiNode.rgba, loNode.intensity, hiNode.intensity,i);
}

int createlutX(int colorscheme, uint32_t* lut) {
    if (colorscheme == 19) { //19=random
        createlutLabel(1, lut, 1.0);
        return EXIT_SUCCESS;
    }
    struct RGBAnode nodes[15];
    nodes[0] = makeRGBAnode(0,0,0,0,0); //assume minimum intensity is black
    nodes[1] = makeRGBAnode(255,255,255,128,256); //assume maximum intensity is white
    int numNodes = 2; //assume 2 nodes, e.g. [0]black [1]white
    //NSLog(@"CreateLUT %d", colorscheme);
    switch (colorscheme) {
        case 1: //hot
            numNodes = 4;
            nodes[0] = makeRGBAnode(3,0,0,0,0);
            nodes[1] = makeRGBAnode(255,0,0,48,96);
            nodes[2] = makeRGBAnode(255,255,0,96,192);
            nodes[3] = makeRGBAnode(255,255,255,128,256);
            break;
        case 2: //2=winter
            numNodes = 3;
            nodes[0] = makeRGBAnode(0,0,255,0,0);
            nodes[1] = makeRGBAnode(0,128,96,64,128);
            nodes[2] = makeRGBAnode(0,255,128,128,256);
            break;
        case 3: //3=warm
            numNodes = 3;
            nodes[0] = makeRGBAnode(255,127,0,0,0);
            nodes[1] = makeRGBAnode(255,196,0,64,128);
            nodes[2] = makeRGBAnode(255,254,0,128,256);
            break;
        case 4: //4=cool
            numNodes = 3;
            nodes[0] = makeRGBAnode(0,127,255,0,0);
            nodes[1] = makeRGBAnode(0,196,255,64,128);
            nodes[2] = makeRGBAnode(0,254,255,128,256);
            break;
        case 5: //5=red/yell
            numNodes = 3;
            nodes[0] = makeRGBAnode(192,1,0,0,0);
            nodes[1] = makeRGBAnode(224,128,0,64,128);
            nodes[2] = makeRGBAnode(255,255,0,128,256);
            break;
        case 6: //6=blue/green
            numNodes = 3;
            nodes[0] = makeRGBAnode(0,1,222,0,0);
            nodes[1] = makeRGBAnode(0,128,127,64,128);
            nodes[2] = makeRGBAnode(0,255,32,128,256);
            break;
        case 7: //7=actc
            numNodes = 5;
            nodes[1] = makeRGBAnode(0,0,136,32,64);
            nodes[2] = makeRGBAnode(24,177,0,64,128);
            nodes[3] = makeRGBAnode(248,254,0,78,156);
            nodes[4] = makeRGBAnode(255,0,0,128,256);
            break;
        case 8: //8=bone
            numNodes = 3;
            nodes[1] = makeRGBAnode(103,126,165,76,153);
            nodes[2] = makeRGBAnode(255,255,255,128,256);
            break;
        case 9: //9=gold
            numNodes = 4;
            nodes[1] = makeRGBAnode(142,85,14,42,85);
            nodes[2] = makeRGBAnode(227,170,76,84,170);
            nodes[3] = makeRGBAnode(255,255,255,128,256);
            break;
        case 10: //10=hotiron
            numNodes = 4;
            nodes[1] = makeRGBAnode(255,0,0,64,128);
            nodes[2] = makeRGBAnode(255,126,0,96,191);
            nodes[3] = makeRGBAnode(255,255,255,128,256);
            break;
        case 11: //11=surface
            numNodes = 3;
            nodes[1] = makeRGBAnode(208,128,128,76,153);
            nodes[2] = makeRGBAnode(255,255,255,128,256);
            break;
        case 12: //12=red
            nodes[1] = makeRGBAnode(255,0,0,128,256);
            break;
        case 13: //13=green
            nodes[1] = makeRGBAnode(0,255,0,128,256);
            break;
        case 14: //14=blue
            nodes[1] = makeRGBAnode(0,0,255,128,256);
            break;
        case 15: //15=cividis
            numNodes = 4;
            nodes[0] = makeRGBAnode(0,32,76,0,0);
            nodes[1] = makeRGBAnode(86,92,108,56,64);
            nodes[2] = makeRGBAnode(166,156,117,88,192);
            nodes[3] = makeRGBAnode(255,233,69,88,256);
            break;
        case 16: //inferno
            numNodes = 4;
            nodes[0] = makeRGBAnode(0,0,4,0,0);
            nodes[1] = makeRGBAnode(120,28,109,56,64);
            nodes[2] = makeRGBAnode(237,105,37,80,192);
            nodes[3] = makeRGBAnode(240,249,33,88,256);
            break;
        case 17: //plasma
            numNodes = 4;
            nodes[0] = makeRGBAnode(13,8,135,0,0);
            nodes[1] = makeRGBAnode(156,23,158,56,64);
            nodes[2] = makeRGBAnode(237,121,83,80,192);
            nodes[3] = makeRGBAnode(240,249,33,88,256);
            break;
        case 18: //viridis
            numNodes = 4;
            nodes[0] = makeRGBAnode(68,1,84,0,0);
            nodes[1] = makeRGBAnode(49,104,142,56,64);
            nodes[2] = makeRGBAnode(53,183,121,80,192);
            nodes[3] = makeRGBAnode(253,231,37,88,256);
            break;
        //19 = random
        case 20: //CT_airways
            numNodes = 4;
            nodes[0] = makeRGBAnode(0,154,179,0,0);
            nodes[1] = makeRGBAnode(0,154,179,32,163);
            nodes[2] = makeRGBAnode(0,154,101,0,254);
            nodes[3] = makeRGBAnode(0,154,101,0,256);
            break;
        case 21: //CT_bone
            numNodes = 3;
            nodes[0] = makeRGBAnode(0,0,0,0,0);
            nodes[1] = makeRGBAnode(113,109,109,64,128);
            nodes[2] = makeRGBAnode(255,250,245,100,256);
            break;
        case 22: //CT_head
            numNodes = 11;
            nodes[0] = makeRGBAnode(0,0,0,0,0);
            nodes[1] = makeRGBAnode(241,156,130,8,2);
            nodes[2] = makeRGBAnode(241,156,130,0,3);
            nodes[3] = makeRGBAnode(248,222,169,0,64);
            nodes[4] = makeRGBAnode(248,222,169,0,122);
            nodes[5] = makeRGBAnode(178,36,24,64,142);
            nodes[6] = makeRGBAnode(178,36,24,64,172);
            nodes[7] = makeRGBAnode(232,51,37,0,182);
            nodes[8] = makeRGBAnode(255,255,255,0,252);
            nodes[9] = makeRGBAnode(255,255,255,222,253);
            nodes[10] = makeRGBAnode(255,255,255,222,256);
            break;
        case 23: //CT_kidneys
            numNodes = 3;
            //nodes[0] = makeRGBAnode(0,0,0,0,0);
            nodes[1] = makeRGBAnode(255,129,0,88,103);
            nodes[2] = makeRGBAnode(255,255,255,228,256);
            break;
        case 24: //CT_soft_tissue
            numNodes = 4;
            nodes[0] = makeRGBAnode(0,0,0,0,0);
            nodes[1] = makeRGBAnode(0,0,0,0,3);
            nodes[2] = makeRGBAnode(199,127,127,48,124);
            nodes[3] = makeRGBAnode(255,255,255,192,256);
            break;
        case 25: //CT_surface
            numNodes = 3;
            //nodes[0] = makeRGBAnode(0,0,0,0,0);
            nodes[1] = makeRGBAnode(134,109,101,60,128);
            nodes[2] = makeRGBAnode(255,250,245,148,256);
            break;
        case 26: //magma (matplotlib, sampled at 0, .25, .5, .75, 1)
            numNodes = 5;
            nodes[0] = makeRGBAnode(0,0,4,0,0);
            nodes[1] = makeRGBAnode(81,18,124,48,64);
            nodes[2] = makeRGBAnode(183,55,121,72,128);
            nodes[3] = makeRGBAnode(252,136,97,84,192);
            nodes[4] = makeRGBAnode(252,253,191,88,256);
            break;
        case 27: //jet (MATLAB/matplotlib rainbow)
            numNodes = 6;
            nodes[0] = makeRGBAnode(0,0,131,0,0);
            nodes[1] = makeRGBAnode(0,0,255,40,32);
            nodes[2] = makeRGBAnode(0,255,255,64,96);
            nodes[3] = makeRGBAnode(255,255,0,80,160);
            nodes[4] = makeRGBAnode(255,0,0,88,224);
            nodes[5] = makeRGBAnode(128,0,0,88,256);
            break;
    }
    for (int i = 1; i < numNodes; i++)
        filllut(nodes[i-1], nodes[i], lut);
    lut[0] = 0;
    
    return EXIT_SUCCESS;
}

uint32_t copyAlpha (uint32_t rgb, uint32_t alpha)
//return RGBA with RGB for rgb and A from Alpha
{
    THIS_UINT8* a = (THIS_UINT8*)&alpha;
    uint32_t ret = rgb;
    THIS_UINT8* pret = (THIS_UINT8*)&ret;
    //pret[0] = a[0]; //linear interpolations
    pret[3] = a[3]; //linear interpolations

    return ret;
}

float getBias (float t, float bias) {
//http://blog.demofox.org/2012/09/24/bias-and-gain-are-your-friend/
    return (t / ((((1.0/bias) - 2.0)*(1.0 - t))+1.0));
}

float getGain (float t, float gain) {
    //http://blog.demofox.org/2012/09/24/bias-and-gain-are-your-friend/
    if(t < 0.5)
        return getBias(t * 2.0,gain)/2.0;
    else
        return getBias(t * 2.0 - 1.0,1.0 - gain)/2.0 + 0.5;
}


int createlut(int colorscheme, uint32_t* lut, float bias)
{
    //float bias = 0.3;
    if ((bias <= 0.0) || (bias >= 1.0) || ((bias > 0.499) && (bias < 0.501) ) )
        return createlutX(colorscheme, lut);
    tRGBAlut luto;
    createlutX(colorscheme, luto);
    for (int clr = 0; clr < 256; clr++) {
        //lut[clr] =  luto[clr];
        float t = (float)clr/255.0;
        float idx = 255.0 * getBias(t, bias);

        //float idx = 255.0 * getBias(t, bias);
        //float idx = 255.0 * (t / ((((1.0/bias) - 2.0)*(1.0 - t))+1.0));
        int i = trunc(idx);
        if (i > 254) i = 254;
        uint32_t lo = luto[i];
        uint32_t hi = luto[i+1];
        int frac = (idx-i) * 100;
        //uint32_t lerprgb (uint32_t lo, uint32_t hi, int loindex, int hiindex, int tarindex)
        lut[clr] = lerprgb(lo,hi, 0,100,frac);
        lut[clr] = copyAlpha(lut[clr], luto[clr]);
        //NSLog(@"%f %f", t, idx);
    }

    return EXIT_SUCCESS;
}

double nii_raw2cal(FSLIO* fslio, double raw)
{
    return (raw * fslio->niftiptr->scl_slope) + fslio->niftiptr->scl_inter;
}

double nii_cal2raw(float scl_inter, float scl_slope, double cal)
{
    return (cal - scl_inter) / scl_slope;
}

int sectionNumber(int x, int y, bool adjustView, NII_PREFS* prefs)
//0=rendering, 1=sagittal, 2= coronal, 3=axial
{
#ifdef NII_IMG_RENDER //defined in nii_definetypes.h
    if (prefs->displayModeGL == GL_3D_ONLY) return 0;
#endif
    float frac[4];
    frac[1] = prefs->sliceFrac[1]; //X-dimension
    frac[2] = prefs->sliceFrac[2]; //Y-dimension (Anterior-Posterio)
    frac[3] = prefs->sliceFrac[3];
    if (prefs->viewRadiological) frac[1] = 1.0 - frac[1]; //test
    int result = 0; //not in section
    if (prefs->displayModeGL == GL_2D_CORONAL) {
        frac[1] =  float(x)/prefs->scrnDim[1];
        frac[3] =  float(y)/prefs->scrnDim[3];
    } else if (prefs->displayModeGL == GL_2D_SAGITTAL) {
            frac[2] =  float(x)/prefs->scrnDim[2];
            frac[3] =  float(y)/prefs->scrnDim[3];
    } else if (prefs->scrnWideLayout) {
        if (x < prefs->scrnDim[1]) {
            frac[1] =  float(x)/prefs->scrnDim[1];
            frac[2] =  float(y)/prefs->scrnDim[2];
            result = 3; //axial slice (click somewhere in 3rd [head/foot] dimension)
        } else if ( x < (2* prefs->scrnDim[1])) {
            frac[1] =  float(x-prefs->scrnDim[1])/prefs->scrnDim[1];
            frac[3] =  float(y)/prefs->scrnDim[3];
            result = 2; //coronal slice
        } else if (x < ((2* prefs->scrnDim[1]) +(prefs->scrnDim[2])) ) {
            frac[2] =  float(x-prefs->scrnDim[1]-prefs->scrnDim[1])/prefs->scrnDim[2];
            frac[3] =  float(y)/prefs->scrnDim[3];
            result = 1; //Sagittal slice (click somewhere in 1st [left/right] dimension)
        } else if (( x < (prefs->renderLeft+prefs->renderWid)) && (y < prefs->renderHt)) {
            return 0; //in rendering
        } else
            return -1; //blank region
    } else {
        //NSLog(@"sector %d %d", y, prefs->scrnDim[2]);
        if (x < prefs->scrnDim[1]) {
            frac[1] =  float(x)/prefs->scrnDim[1];
            if (y < prefs->scrnDim[2]) {
                frac[2] =  float(y)/prefs->scrnDim[2];
                result = 3; //axial slice (click somewhere in 3rd [head/foot] dimension)
            } else if (y < (prefs->scrnDim[2]+prefs->scrnDim[3])) {
                frac[3] =  float(y-prefs->scrnDim[2])/prefs->scrnDim[3];
                result = 2; //coronal slice (click somewhere in 2nd [anterior/posterior] dimension)
            } else {
                return -1; //blank region
            }
        } else if ((x < (prefs->scrnDim[1]+prefs->scrnDim[2]) ) && ((y >= prefs->scrnDim[2]) && (y < (prefs->scrnDim[2]+prefs->scrnDim[3])) )) {
            //NSLog(@"Sagittal");
            frac[2] =  float(x-prefs->scrnDim[1])/prefs->scrnDim[2];
            frac[3] =  float(y-prefs->scrnDim[2])/prefs->scrnDim[3];
            result = 1; //Sagittal slice (click somewhere in 1st [left/right] dimension)
        } else if (( x < (prefs->renderLeft+prefs->renderWid)) && (y < prefs->renderHt)) {
            return 0; //on rendering
        } else
            return -1; //blank region
    }
    if ((frac[1] < 0.0) || (frac[1] > 1.0) || (frac[2] < 0.0) || (frac[2] > 1.0) || (frac[3] < 0.0) || (frac[3] > 1.0)) return -1;
    frac2slice (frac, prefs); //set tempSliceVox
    if (!adjustView) return result;
        if (prefs->viewRadiological) frac[1] = 1.0 - frac[1];//2015
    //frac2mm(frac, prefs, false);
    frac2mm(frac, prefs, true);
    NSDictionary *dict;
    dict = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithFloat:prefs->mm[1]], @"x",
            [NSNumber numberWithFloat:prefs->mm[2]], @"y",
            [NSNumber numberWithFloat:prefs->mm[3]], @"z",
            nil]; //precision of prefs->mm type, e.g. numberWithDouble
    [[NSNotificationCenter defaultCenter] postNotificationName:@"niiChanged" object:nil userInfo:dict];
    //NSValue *wrapper = [NSValue valueWithPoint: xy];
    //NSValue *wrapper = [NSValue valueWithPoint: xy];
    //[[NSNotificationCenter defaultCenter] postNotificationName:@"NoteFromOne" object:wrapper];
    prefs->force_refreshGL = true;
    return result;
}

-(bool) setRightMouseUp: (int) x Y: (int) y;
{
    if ((prefs->mouseDownX) < 0) return FALSE;
    if (fslio->niftiptr->intent_code == NIFTI_INTENT_LABEL) return FALSE;
    prefs->mouseX = x;
    prefs->mouseY = y;
    if ((prefs->mouseDownX == prefs->mouseX) && (prefs->mouseDownY == prefs->mouseY)) return FALSE;
    int sectionDown = sectionNumber(prefs->mouseDownX, prefs->mouseDownY, false, prefs);
    int sliceVox[4];
    for (int j = 1; j < 4; j++)
        sliceVox[j] = prefs->tempSliceVox[j];
    int sectionUp = sectionNumber(prefs->mouseX, prefs->mouseY, false, prefs);
    if ((sectionDown == 0) ||(sectionDown != sectionUp) ) return FALSE; //exit if click on render or dragged across different views
    //NSLog(@"x %d..%d, y %d..%d",prefs->mouseDownX, prefs->mouseX, prefs->mouseDownY, prefs->mouseY);
    int sliceVoxHi[4];
    for (int j = 1; j < 4; j++) {
        sliceVoxHi[j] = prefs->tempSliceVox[j];
        if (sliceVoxHi[j] < sliceVox[j]) {
            int swap = sliceVoxHi[j];
            sliceVoxHi[j] = sliceVox[j];
            sliceVox[j] = swap;
        } //set order
    } //for each dimension
    //NSLog(@"x=%d..%d, y=%d..%d, z=%d..%d",sliceVox[1], sliceVoxHi[1], sliceVox[2], sliceVoxHi[2],sliceVox[3], sliceVoxHi[3]);
    double mn = INFINITY;
    double mx = -INFINITY;
    long long vol = prefs->numVox3D * (prefs->currentVolume-1);
    for (int z = sliceVox[3]; z <= sliceVoxHi[3]; z++) {
        long long slice = (z*prefs->voxelDim[1]*prefs->voxelDim[2])+ vol;
        for (int y = sliceVox[2]; y <= sliceVoxHi[2]; y++) {
            long long row = slice+(y*prefs->voxelDim[1]);
                for (int x = sliceVox[1]; x <= sliceVoxHi[1]; x++) {
                    double v = getVoxelIntensity(row+x, fslio);
                    if (v > mx) mx = v;
                    if (v < mn) mn = v;
                } //for z
        } //for y
    } //for z
    if ((mn == -INFINITY) || (mx == INFINITY) ) return FALSE;
    if (mn == mx ) return FALSE;
    //NSLog(@"x=%d..%d, y=%d..%d, z=%d..%d intensity %f..%f",sliceVox[1], sliceVoxHi[1], sliceVox[2], sliceVoxHi[2],sliceVox[3], sliceVoxHi[3], mn, mx);
    prefs->viewMin = mn;
    prefs->viewMax = mx;
    prefs->force_recalcGL = true;
    prefs->force_refreshGL = true;
    return TRUE;
   //[[NSNotificationCenter defaultCenter] postNotificationName:@"niiUpdate" object:self userInfo:nil];
}

int isInSection (int x, int y, bool adjustView, NII_PREFS* prefs, FSLIO* fslio)
{
#ifdef NII_IMG_RENDER //defined in nii_definetypes.h
    if (prefs->displayModeGL == GL_3D_ONLY) return 0;
#endif
    prefs->updatedTimeline = (prefs->numVolumes > 1); //for multivolume data, the user should refresh timeline at their convenience....
    int result = sectionNumber(x, y, adjustView, prefs);
    if (!result) return result;
    getIntensity(prefs, fslio);
    return result;
}

-(void) changeClipDepth: (float) x; {
    if (x == 0) return;
    [self setClip: prefs->clipAzimuth Elev: prefs->clipElevation Depth: prefs->clipDepth+x];
}

- (void) changeClipPlane: (int) x Y: (int) y;
{
    if (self.is2D) return;
    if (x < 0)
        prefs->clipAzimuth = prefs->clipAzimuth +5;
    if (x > 0)
        prefs->clipAzimuth = prefs->clipAzimuth - 5;
    if (y > 0)
        prefs->clipElevation = prefs->clipElevation+5;
    if (y < 0)
        prefs->clipElevation = prefs->clipElevation - 5;
    if (prefs->clipElevation < -360)
        prefs->clipElevation = prefs->clipElevation + 360;
    if (prefs->clipElevation > 360)
        prefs->clipElevation = prefs->clipElevation - 360;
/*    if (prefs->clipElevation < -90)
        prefs->clipElevation = -90;
    if (prefs->clipElevation > 90)
        prefs->clipElevation = 90;*/
    prefs->force_refreshGL = true;
    //NSLog(@"%d %d Change clip %d %d",x, y, prefs->clipAzimuth,  prefs->clipElevation);

}

-(bool) magnifyRender: (float) delta;
{
    //NSLog(@"swipe %g",delta);

    if ((delta == 0.0) || (isInSection(prefs->mouseX,prefs->mouseY, FALSE, prefs, fslio))) return false; //not for 2D slices, only rendering
    //NSLog(@"magnifyRender %g",delta);
    float dx = prefs->renderDistance;
    const float kMinRender = 0.5;
    const float kMaxRender = 5.0;
    const float kStepRender = 0.1;

    if (delta < 0)
        dx -= kStepRender;
    else
        dx += kStepRender;
    if (dx < kMinRender) dx = kMinRender;
    if (dx > kMaxRender) dx = kMaxRender;

    prefs->renderDistance = dx;
    //NSLog(@"magnifyRender %g",dx);
    prefs->force_refreshGL = true;
    return true;
}

/*-(bool) doSwipe: (float) x Y: (int) y; {
    if ((x == 0.0) && (x == 0.0)) return false;
    if  (isInSection(prefs->mouseX,prefs->mouseY, FALSE, prefs, fslio)) return false; //not for 2D slices, only rendering
    [self changeClipPlane: x Y: y];
    return true;

}*/

-(void) setRightMouseDragXY: (int) x Y: (int) y isMag: (bool) mag isSwipe: (bool) swipe;
//-(void) setRightMouseDragY: (int) y isMag: (bool) mag isSwipe: (bool) swipe;
{
    int dx = prefs->mouseX - x;
    int dy = prefs->mouseY - y;
    if ((dy == 0) && (dx == 0) ) return;
    if ((!self.is2D)  && (!isInSection(prefs->mouseX,y, FALSE, prefs, fslio))) {
        if ((mag) && (dy != 0))
                [self magnifyRender: dy];
        else if (swipe)
            //[self doSwipe: x Y: y];
            [self changeClipPlane: dx Y: -dy];
        else if  (dy != 0)
            [self changeClipDepth : dy*5];
    }
    prefs->mouseY = y;
    prefs->mouseX = x;
}


/*-(void) setRightMouseDragX: (int) x;
{
    int dxDown = abs(prefs->mouseDownX - x); //at least 3 voxels vertical to trigger effect
    int dx = x - prefs->mouseX; //we will use a 3 voxel tolerance before making a change
    if ((dxDown > 8) && (dx != 0) && (!self.is2D)  && (!isInSection(x,prefs->mouseY, FALSE, prefs, fslio)))
        [self magnifyRender: dx];
    prefs->mouseX = x;
}*/
/*-(void) setRightMouseDrag: (int) x Y: (int) y;
{
    if (isInSection(x,y, FALSE, prefs, fslio)) { //user clicked in 2D section
        prefs->mouseX = x;
        prefs->mouseY = y;
        return;
    }
#ifdef NII_IMG_RENDER //defined in nii_definetypes.h
    if (self.is2D) return;
    [self changeClipDepth : (x - prefs->mouseX)];
    [self magnifyRender: (y - prefs->mouseY)];
    prefs->mouseX = x;
    prefs->mouseY = y;

    //NSLog(@"nii_img right-drag %d %d", prefs->clipAzimuth, prefs->clipElevation);
#endif
}*/

-(void) setSwipe: (float) x Y: (float) y;
{
    //NSLog(@"swipe %g %g",x,y);
    if (!isInSection(prefs->mouseX,prefs->mouseY, FALSE, prefs, fslio)) {
        if (x > 0)
            [self changeClipDepth: -25]; // prefs->clipDepth = prefs->clipDepth - 25;
        else if (x < 0)
            [self changeClipDepth: +25]; //prefs->clipDepth = prefs->clipDepth + 25;

        //NSLog(@"new clip %d", prefs->clipDepth);
        [self setClip: prefs->clipAzimuth Elev: prefs->clipElevation Depth: prefs->clipDepth];
        //[self changeClipPlane: x Y:  y];

        return; //only for 2D slices, not rendering

    }if (prefs->numVolumes > 1) {
        //if (isInSection(prefs->mouseX,prefs->mouseY, FALSE, prefs, fslio)) {
            //NSLog(@"swipe %d %d",prefs->mouseX,prefs->mouseY);
            int v =prefs->currentVolume;
            if (x > 0)
                v ++;
            else
                v--;
            [self setVolume: v];
        //}
    }
}


-(void) setMagnify: (float) delta;
{
    [self magnifyRender : -delta];
}

-(bool) setScrollWheel:  (float) x Y: (float) delta locX: (float) mouseX locY: (float) mouseY;
{
    if ((x == 0) && (delta == 0)) return false; //nothing to do
    int deltaDx = 1;
    if (delta < 0) deltaDx = -1;
    switch (prefs->displayModeGL) {
        case   GL_2D_AXIAL:
            [self  changeXYZvoxel:0 Y: 0 Z: deltaDx];
            return true;
        case  GL_2D_CORONAL:
            [self  changeXYZvoxel:0 Y: deltaDx Z: 0];
            return true;
        case   GL_2D_SAGITTAL:
            [self  changeXYZvoxel:deltaDx Y: 0 Z: 0];
            return true;
    }
    int numOverlay = 0;
    for (int i = 0; i < MAX_OVERLAY; i++)
        if (prefs->overlays[i].datatype != DT_NONE) numOverlay++; //filled slot
    int sect = sectionNumber(mouseX, mouseY, FALSE, prefs);
    //int sect = sectionNumber(prefs->mouseX, prefs->mouseY, FALSE, prefs);
    //NSLog(@"Sector %d", sect);
    switch (sect) { //0=rendering, 1=sagittal, 2= coronal, 3=axial
        case   3: //GL_2D_AXIAL:
            [self  changeXYZvoxel:0 Y: 0 Z: deltaDx];
            return true;
        case  2: //GL_2D_CORONAL:
            [self  changeXYZvoxel:0 Y: deltaDx Z: 0];
            return true;
        case  1: // GL_2D_SAGITTAL:
            [self  changeXYZvoxel:deltaDx Y: 0 Z: 0];
            return true;
    }
    
    if ((sect <1) || (sect >3) || ((prefs->numVolumes < 2) == (numOverlay == 0))) //not on one of the canonical slices - adjust rendering
    {
        [self changeClipPlane: x Y: delta];
        //prefs->clipDepth = prefs->clipDepth - (5* delta);
        //[self setClip: prefs->clipAzimuth Elev: prefs->clipElevation Depth: prefs->clipDepth];
        return true;
    }
    if (prefs->numVolumes > 1) {
        int v =prefs->currentVolume;
        if (delta > 0)
            v ++;
        else
            v--;
        [self setVolume: v];
        return true;
    }
    //scroll wheel over 2D slices with overlay - adjust opacity
    float startFrac = prefs->overlayFrac;
    if (delta > 0)
        prefs->overlayFrac = prefs->overlayFrac+0.1;
    else
        prefs->overlayFrac = prefs->overlayFrac-0.1;
    if (prefs->overlayFrac > 1.1)
        prefs->overlayFrac = 1.1; //1.1 mean additive
    if (prefs->overlayFrac < 0.1)
        prefs->overlayFrac = 0.1;
    if (startFrac == prefs->overlayFrac) return false;
    prefs->force_recalcGL = true;
    prefs->force_refreshGL = true;
    return true;
}


-(void) setMouseDrag: (int) x Y: (int) y;
{
    if (isInSection(x,y, TRUE, prefs, fslio)) return; //user clicked in 2D section
    #ifdef NII_IMG_RENDER //defined in nii_definetypes.h
    if (self.is2D) return;
    //if (prefs->displayModeGL == GL_2D_ONLY) return;
    [self setAzimElevInc: (x-prefs->mouseX) Elev: (prefs->mouseY-y)];
    prefs->mouseX = x;
    prefs->mouseY = y;
    prefs->force_refreshGL = true;
    #endif
}

-(void) setMouseDown: (int) x Y: (int) y;
{
    prefs->mouseDownX = x;
    prefs->mouseDownY = y;
    prefs->mouseX = x;
    prefs->mouseY = y;
    isInSection(x,y, TRUE, prefs, fslio);
}

void rescale16to8bit (void *data, size_t nvox, size_t voxOffset, int datatype, THIS_UINT8 *img8bit)
{
    if (datatype != NIFTI_TYPE_INT16) {
        NSLog(@"16-bit only!");
        return;
    }
    THIS_UINT8 *ptr = img8bit;
    size_t start = voxOffset;
    size_t end = voxOffset + nvox;
    THIS_INT16 *raw16 = (THIS_INT16 *) data;
    THIS_INT16 raw;
    for (size_t i = start; i < end; i++) {
        raw = raw16[i];
        if (raw == 0)
            *ptr++ = 0;
        else
            *ptr++ = ((raw-1) % 100)+1;
    } //for each voxel
}

void rescale8bit (void *data, size_t nvox, size_t voxOffset, int datatype, double minRaw, double maxRaw, THIS_UINT8 *img8bit)
//provided input volume data with numvoxels each of datatype, a scaled 8 bit image is generated
//WARNING: you must call subsequently call     free(img8bit);
{
    //img8bit = (THIS_UINT8 *) m alloc(nvox);
    size_t start = voxOffset;
    size_t end = voxOffset + nvox;
    THIS_UINT8 *ptr = img8bit;
    double slope = 255.0/(maxRaw-minRaw);
    if ( datatype == NIFTI_TYPE_UINT8) {
        THIS_UINT8 *raw8 = (THIS_UINT8 *) data;
        //create lookup table to convert raw 8 bit data to scaled 8 bit data
        const long kBins8 = 256; //for 8 bit data, 256 bins provide complete coverage
        THIS_UINT8 bins[kBins8];
        for (long k = 0; k < kBins8; k++) {
            if (k < minRaw)
                bins[k] = 0;
            else if (k > maxRaw)
                bins[k] =255;
            else
                bins[k] = (k-minRaw)*slope;
        } //for each bin
        // unfortunately XCode 5's clang does not support openMP... #pragma omp parallel for
        for (size_t i = start; i < end; i++)
            *ptr++ =  bins[raw8[i]];
    } else if (datatype == NIFTI_TYPE_INT16) {
        THIS_INT16 *raw16 = (THIS_INT16 *) data;
        THIS_INT16 raw;
        for (size_t i = start; i < end; i++) {
            raw = raw16[i];
            if (raw < minRaw)
                *ptr++ = 0;
            else if (raw > maxRaw)
                *ptr++ =255;
            else
                *ptr++ = (raw-minRaw)*slope;
        } //for each voxel
    } else if (datatype == NIFTI_TYPE_RGBA32) {
        //nothing to do
    } else if (datatype == NIFTI_TYPE_FLOAT32 ) { //666 TRUE
        SCALED_IMGDATA *rawf = (SCALED_IMGDATA *) data;
        SCALED_IMGDATA raw;
        for (size_t i = start; i < end; i++) {
            raw = rawf[i];
            if (raw < minRaw)
                *ptr++ = 0;
            else if (raw > maxRaw)
                *ptr++ =255;
            else
                *ptr++ = (raw-minRaw)*slope;
        }
    } else
        NSLog(@"makergb: Unsupported data type!");
}

void computeBlendAdditive (void* back, void* over, size_t nvox)
{
    THIS_UINT8 *backPtr = (THIS_UINT8 *) back;
    THIS_UINT8 *overPtr = (THIS_UINT8 *) over;
    for (size_t vx=0; vx<(nvox*4); vx++) {
        if (*overPtr > *backPtr) *backPtr = *overPtr;
        backPtr++; overPtr++;
    }
}

void computeBlend (void* back, void* over, size_t nvox, float overlayFraction)
{
    if ((overlayFraction < 0) || (overlayFraction > 1.0)  ) {
        computeBlendAdditive(back, over, nvox);
        return;
    }
    int overFrac = round(256*overlayFraction);
    int backFrac = (256-overFrac);
    THIS_UINT8 *backPtr = (THIS_UINT8 *) back;
    THIS_UINT8 *overPtr = (THIS_UINT8 *) over;
    uint32_t *over32Ptr = (uint32_t *) over;
    for (size_t vx=0; vx<(nvox); vx++) {
        if ( *over32Ptr++ > 0) {
            *backPtr = ((*overPtr * overFrac)+(*backPtr * backFrac) ) >>8 ;
            backPtr++; overPtr++;
            *backPtr = ((*overPtr * overFrac)+(*backPtr * backFrac) ) >>8;
            backPtr++; overPtr++;
            *backPtr = ((*overPtr * overFrac)+(*backPtr * backFrac) ) >> 8;
            backPtr++; overPtr++;
            //alpha channel based on background only...
            backPtr++; overPtr++;
        } else {
            backPtr+= 4;
            overPtr+= 4;
        }
    } //for each voxel
}

void computeBlendEither (void* back, void* over, size_t nvox, float overlayFraction)
{
    if ((overlayFraction < 0)  || (overlayFraction > 1.0)) {
        computeBlendAdditive(back, over, nvox);
        return;
    }
    int overFrac = round(256*overlayFraction);
    int backFrac = (256-overFrac);
    THIS_UINT8 *backPtr = (THIS_UINT8 *) back;
    THIS_UINT8 *overPtr = (THIS_UINT8 *) over;
    uint32_t *back32Ptr = (uint32_t *) back;
    uint32_t *over32Ptr = (uint32_t *) over;
    for (size_t vx=0; vx<(nvox); vx++) {
        if (( *over32Ptr > 0) && ( *back32Ptr > 0) ) {
            *backPtr = ((*overPtr * overFrac)+(*backPtr * backFrac) ) >>8 ;
            backPtr++; overPtr++;
            *backPtr = ((*overPtr * overFrac)+(*backPtr * backFrac) ) >>8;
            backPtr++; overPtr++;
            *backPtr = ((*overPtr * overFrac)+(*backPtr * backFrac) )>> 8;
            backPtr++; overPtr++;
            //alpha channel based on background only...
            backPtr++; overPtr++;
        } else if ( *over32Ptr > 0) {
            *backPtr = *overPtr;
            backPtr++; overPtr++;
            *backPtr = *overPtr;
            backPtr++; overPtr++;
            *backPtr = *overPtr ;
            backPtr++; overPtr++;
            *backPtr = *overPtr ;
            backPtr++; overPtr++;
        }else {
            backPtr+= 4;
            overPtr+= 4;
        }
        back32Ptr++; over32Ptr++;
    }
}

#ifndef MY_USE_GLSL_FOR_GRADIENTS //defined in nii_render.h

void smoothVol32(THIS_INT32 *img, int Xdim, int Ydim, int Zdim) {
    //roughly emulutes a tight Gaussian blur, wraps images L/R, A/P
    //image intensity increased 729 times (9*9*9), so 8-bit input returns as 32-bit, maximum value input = 255, output = 185895 so we use ~18 bits
    //http://rastergrid.com/blog/2010/09/efficient-gaussian-blur-with-linear-sampling/
    if ((Xdim < 5) || (Ydim < 5) || (Zdim < 5)) return;
    int nvox = Xdim * Ydim * Zdim;
    THIS_INT32 *sum = new THIS_INT32[nvox]();
    memcpy (sum, img, nvox*sizeof(THIS_INT32)); //memcpy(destination, source)
    //sum with left/right neighbors
    for (int i = 2; i < (nvox-2); i++)
        img[i] = sum[i-1]+ (sum[i] << 1)+ sum[i+1];// left+2*center+right
    //int Xdim2 = Xdim * 2;
    //sum result with anterior/posterior neighbors
    for (int i = Xdim; i < (nvox-Xdim-1); i++)
        sum[i] = img[i-Xdim] + (img[i] << 1) + img[i+Xdim];// anterior+2*center+posterior
    //sum with superior/inferior neighbors, generate output
    int sliceSz = Xdim*Ydim;
    //int sliceSz2 = sliceSz * 2;
    for (int i = sliceSz; i < (nvox-sliceSz-1); i++)
        img[i] = (sum[i-sliceSz] + (sum[i] << 1)+ sum[i+sliceSz]) >> 4 ; //shift right AT LEAST 3
    delete[] sum;
}

void computeGradientsCPU (NII_PREFS* prefs, uint32_t *img) {
    if ((prefs->voxelDim[1] < 5) || (prefs->voxelDim[2]<5) || (prefs->voxelDim[3] < 5)) return;
    int nvox = prefs->voxelDim[1]*prefs->voxelDim[2]*prefs->voxelDim[3];
    #ifdef MY_DEBUG //from nii_io.h
    NSDate *methodStart = [NSDate date];
    #endif
    THIS_INT32 *img32bit = (THIS_INT32 *) malloc(nvox*sizeof(THIS_INT32));
    for (int i = 0; i < nvox; i++) img32bit[i] = img[i] & 0xFF;
    smoothVol32(img32bit, prefs->voxelDim[1], prefs->voxelDim[2], prefs->voxelDim[3]);
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"smooth = %f", [[NSDate date] timeIntervalSinceDate:methodStart]);
    methodStart = [NSDate date];
    #endif
    THIS_INT32 *mag = new THIS_INT32[nvox](); //*4 as RGBA
    int I;
    THIS_INT32 Xm,Ym,Zm,aXm,aYm,aZm, mx;
    int colSz = prefs->voxelDim[1];
    int sliceSz = prefs->voxelDim[1]*prefs->voxelDim[2]; //each plane is X*Y voxels
    for (int Z = 1; Z < prefs->voxelDim[3] - 2; Z++) {   //for X,Y,Z dimensions indexed from zero, so := 1 gives 1 voxel border
        for (int Y = 1; Y < prefs->voxelDim[2] - 2; Y++) {   //for X,Y,Z dimensions indexed from zero, so := 1 gives 1 voxel border
            int Index = (Z * prefs->voxelDim[1]*prefs->voxelDim[2]) + (Y * prefs->voxelDim[1]);
            for (int X = 1; X < prefs->voxelDim[1] - 2; X++) {   //for X,Y,Z dimensions indexed from zero, so := 1 gives 1 voxel border
                I = Index+X;
                if (img32bit[I] > 0) { //intensity less than threshold: make invisible
                    Xm = img32bit[I-1]-img32bit[I+1];
                    Ym = img32bit[I-colSz]-img32bit[I+colSz];
                    Zm = img32bit[I-sliceSz]-img32bit[I+sliceSz];
                    aXm = abs(Xm);
                    aYm = abs(Ym);
                    aZm = abs(Zm);
                    mx = aXm;
                    if (aYm > mx) mx = aYm;
                    if (aZm > mx) mx = aZm;
                    if (mx > 0) {
                        mag[I] = aXm+aYm+aZm;//gradient magnitude = quick, precise would be sqrt(Xm^2+Ym^2+Zm^2)
                        Xm = ((255+((253*Xm)/mx))>>1);
                        Ym = ((255+((253*Ym)/mx))>>1);
                        Zm = ((255+((253*Zm)/mx))>>1);
                        img[I] = char(Xm) + (char(Ym) << 8) + (char(Zm) << 16);
                    }
                } //img32bit[I] > 0
                //data[I] = CentralDifference (img32bit, colSz, sliceSz, I, &mag[I]);
            }//X
        }//Y
    }//Z
    free(img32bit);
    //methodStart = [NSDate date];
    //normalize magnitude
    mx = mag[0];
    for (int i = 0; i < nvox; i++)
        if (mag[i] > mx) mx = mag[i];
    if (mx > 0 ) {
        float scale = 255.0f/mx; //we will save as a byte with range 0..255
        for (int i = 0; i < nvox; i++)
            img[i] = img[i] + ((char)((mag[i])*scale) << 24);
    }
    delete[] mag;
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"sobel = %f", [[NSDate date] timeIntervalSinceDate:methodStart]);
    #endif
}
#endif

void computeGradients (NII_PREFS* prefs, uint32_t *img, bool isOverlay) {
    // Gradients are computed by the Metal Sobel compute kernel
    // (NIIMetalRenderer recomputeGradients, driven by the volume-upload hook).
    (void)prefs; (void)img; (void)isOverlay;
}

// Per-window upload target. Set by redrawMetalInView before recalc, so the
// recalcSub* upload hooks feed THIS window's renderer (not a shared singleton).
static NIIMetalRenderer *gCurrentRenderer = nil;
static void niiMetalUploadVolumeToCurrent(NII_PREFS *prefs, const void *data) {
    if (!gCurrentRenderer || !data) return;
    [gCurrentRenderer uploadIntensityVolume:data dims:prefs->voxelDim];
    [gCurrentRenderer recomputeGradients]; // intensity + (if present) overlay gradients
}
// Upload (overdata != NULL) or clear (NULL) the overlay layer so the advanced
// shader's overlay pass samples real overlay voxels (texture 1) and their Sobel
// gradient (texture 3) instead of falling back to the intensity volume.
static void niiMetalUploadOverlayToCurrent(NII_PREFS *prefs, const void *overdata) {
    if (!gCurrentRenderer) return;
    [gCurrentRenderer uploadOverlayVolume:overdata dims:prefs->voxelDim];
}

void blendOverlays(NII_PREFS* prefs, uint32_t *data)
{
    prefs->numOverlay = 0;
    niiMetalUploadOverlayToCurrent(prefs, NULL); // clear any prior overlay layer
    if (prefs->overlayFrac == 0) return; //overlays do not contribute to image
    //NSLog(@"test %d ", ((255*0) + (255*255)) >> 8);
    int numOverlay = 0;
    for (int i = 0; i < MAX_OVERLAY; i++)
        if (prefs->overlays[i].datatype != DT_NONE) numOverlay++; //filled slot
    if (numOverlay == 0) return; //no overlays
    prefs->numOverlay = numOverlay;
    size_t nvox = prefs->numVox3D; //voxelDim[1]*prefs->voxelDim[2]*prefs->voxelDim[3];
    //uint32_t clearclr = makeRGBA(prefs->BackColor[0]*255, prefs->BackColor[1]*255,prefs->BackColor[2]*255,0);
    uint32_t *overdata = new uint32_t[nvox]; // *4 as RGBA
    numOverlay = 0;
    for (int i = 0; i < MAX_OVERLAY; i++) {
        if (prefs->overlays[i].datatype != DT_NONE) {
            numOverlay++;
            tRGBAlut lut;
            createlut(prefs->overlays[i].colorScheme, lut, prefs->overlays[i].lut_bias);
            createlut(prefs->overlays[i].colorScheme, prefs->overlays[i].lut, prefs->overlays[i].lut_bias);
            double minRaw = nii_cal2raw(prefs->overlays[i].scl_inter, prefs->overlays[i].scl_slope, prefs->overlays[i].viewMin);
            double maxRaw = nii_cal2raw(prefs->overlays[i].scl_inter, prefs->overlays[i].scl_slope, prefs->overlays[i].viewMax);
            if ((minRaw <0.0) && (maxRaw < 0.0)) {
                //reverse polarity so more extreme values look brighter
                for (int c = 0; c < 256; c++)
                    lut[255-c] = prefs->overlays[i].lut[c];
                for (int c = 0; c < 256; c++)
                    prefs->overlays[i].lut[c] = lut[c];
            }
            THIS_UINT8 *img8bit = (THIS_UINT8 *) malloc(nvox);
            rescale8bit (prefs->overlays[i].data, nvox, 0, prefs->overlays[i].datatype, minRaw, maxRaw, img8bit);
            if (numOverlay == 1) { //first overlay defines colors...
                uint32_t *ptr = overdata;
                for (size_t v = 0; v < nvox; v++)
                    *ptr++ = lut[ img8bit[v]];
            } else { //additional overlay
                uint32_t *overdataAdd = new uint32_t[nvox]; // *4 as RGBA
                uint32_t *ptrAdd = overdataAdd;
                for (size_t v = 0; v < nvox; v++)
                    *ptrAdd++ = lut[img8bit[v]];
                //computeBlendEither(overdata, overdataAdd, nvox, prefs->overlayFrac);
                computeBlendEither(overdata, overdataAdd, nvox, 0.5);
                delete[] overdataAdd;//2014 free(overdataAdd);
            }
            free(img8bit);
        }
    }
    computeBlend(data, overdata, nvox, prefs->overlayFrac);
        // overlay voxels are blended into `data` (for 2D slices + the background
        // ray-cast pass), AND uploaded as a SEPARATE overlay layer so the advanced
        // shader's overlay pass can depth-composite it (matches the GL path's
        // intensityOverlay3D + its Sobel gradient).
    niiMetalUploadOverlayToCurrent(prefs, overdata); // recomputeGradients (run after
        // the intensity upload in recalcSubGL) then computes the overlay gradient too.
    delete[] overdata;//2014 free(overdata);
}


// ---------------------------------------------------------------------------------
// Streaming overlays.
//
// The normal overlay path (addOverlay) rebuilds everything: rescale the background to
// 8-bit, map it through the LUT, rescale and colour every overlay, blend, and upload two
// whole-volume textures. That is fine for loading a stat map once and far too expensive
// for data that changes many times a second — a running simulation, say — where it caps
// the update rate and stalls the UI on every frame.
//
// The streaming path keeps the background's 8-bit rescale (cached8bit, refreshed by
// recalcGL whenever the background itself changes) and re-composes only the voxel box the
// new data touches, uploading that box into the existing textures.
// ---------------------------------------------------------------------------------

void cacheBackground8bit(NII_PREFS* prefs, const THIS_UINT8 *img8bit) {
    size_t nvox = prefs->numVox3D;
    if (nvox < 1) return;
    if (prefs->cached8bitVox != nvox) {
        free(prefs->cached8bit);
        prefs->cached8bit = (THIS_UINT8 *) malloc(nvox);
        prefs->cached8bitVox = (prefs->cached8bit == NULL) ? 0 : nvox;
    }
    if (prefs->cached8bit) memcpy(prefs->cached8bit, img8bit, nvox);
}

void freeCached8bit(NII_PREFS* prefs) {
    free(prefs->cached8bit);
    prefs->cached8bit = NULL;
    prefs->cached8bitVox = 0;
}

// Re-compose prefs->overlayDirty* and upload just that box. Returns false when the
// preconditions are missing (no cache, no textures yet), in which case the caller must
// fall back to the full rebuild.
bool refreshOverlayRegionGL(NII_PREFS* prefs) {
    if (!prefs->cached8bit || prefs->cached8bitVox != prefs->numVox3D) return false;
    if (!gCurrentRenderer || ![gCurrentRenderer hasIntensityVolume]) return false;
    const int nx = prefs->voxelDim[1], ny = prefs->voxelDim[2], nz = prefs->voxelDim[3];
    int lo[3], hi[3];
    for (int d = 0; d < 3; d++) {
        lo[d] = prefs->overlayDirtyLo[d];
        hi[d] = prefs->overlayDirtyHi[d];
    }
    const int dim[3] = {nx, ny, nz};
    for (int d = 0; d < 3; d++) {
        if (lo[d] < 0) lo[d] = 0;
        if (hi[d] > dim[d] - 1) hi[d] = dim[d] - 1;
        if (lo[d] > hi[d]) return false; //empty box: nothing to do
    }
    const int size[3] = {hi[0]-lo[0]+1, hi[1]-lo[1]+1, hi[2]-lo[2]+1};
    const size_t boxVox = (size_t)size[0] * size[1] * size[2];

    int numOverlay = 0;
    for (int i = 0; i < MAX_OVERLAY; i++)
        if (prefs->overlays[i].datatype != DT_NONE) numOverlay++;
    prefs->numOverlay = numOverlay;

    uint32_t *base = new uint32_t[boxVox];
    // Background colours for the box, straight from the cached rescale.
    {
        size_t k = 0;
        for (int z = lo[2]; z <= hi[2]; z++)
            for (int y = lo[1]; y <= hi[1]; y++) {
                const size_t row = (size_t)z * nx * ny + (size_t)y * nx;
                for (int x = lo[0]; x <= hi[0]; x++)
                    base[k++] = prefs->lut[prefs->cached8bit[row + x]];
            }
    }

    uint32_t *over = NULL;
    if (numOverlay > 0 && prefs->overlayFrac != 0) {
        over = new uint32_t[boxVox];
        THIS_UINT8 *row8 = (THIS_UINT8 *) malloc(size[0]);
        int seen = 0;
        for (int i = 0; i < MAX_OVERLAY; i++) {
            if (prefs->overlays[i].datatype == DT_NONE) continue;
            seen++;
            tRGBAlut lut;
            createlut(prefs->overlays[i].colorScheme, lut, prefs->overlays[i].lut_bias);
            createlut(prefs->overlays[i].colorScheme, prefs->overlays[i].lut, prefs->overlays[i].lut_bias);
            double minRaw = nii_cal2raw(prefs->overlays[i].scl_inter, prefs->overlays[i].scl_slope, prefs->overlays[i].viewMin);
            double maxRaw = nii_cal2raw(prefs->overlays[i].scl_inter, prefs->overlays[i].scl_slope, prefs->overlays[i].viewMax);
            if ((minRaw < 0.0) && (maxRaw < 0.0)) { //reverse polarity, as blendOverlays does
                for (int c = 0; c < 256; c++) lut[255-c] = prefs->overlays[i].lut[c];
                for (int c = 0; c < 256; c++) prefs->overlays[i].lut[c] = lut[c];
            }
            uint32_t *dst = (seen == 1) ? over : new uint32_t[boxVox];
            size_t k = 0;
            // rescale8bit one x-run at a time: it already handles every datatype, and a
            // run is contiguous in the source volume.
            for (int z = lo[2]; z <= hi[2]; z++)
                for (int y = lo[1]; y <= hi[1]; y++) {
                    const size_t row = (size_t)z * nx * ny + (size_t)y * nx + lo[0];
                    rescale8bit(prefs->overlays[i].data, size[0], row,
                                prefs->overlays[i].datatype, minRaw, maxRaw, row8);
                    for (int x = 0; x < size[0]; x++) dst[k++] = lut[row8[x]];
                }
            if (seen > 1) {
                computeBlendEither(over, dst, boxVox, 0.5); //matches blendOverlays
                delete[] dst;
            }
        }
        free(row8);
        computeBlend(base, over, boxVox, prefs->overlayFrac);
    }

    const int origin[3] = {lo[0], lo[1], lo[2]};
    bool ok = [gCurrentRenderer replaceIntensityRegion:base origin:origin size:size];
    if (ok && over) {
        if (![gCurrentRenderer hasOverlayVolume]) {
            ok = false; //no overlay texture yet: the full path has to create it
        } else {
            [gCurrentRenderer replaceOverlayRegion:over origin:origin size:size];
        }
    }
    delete[] base;
    delete[] over;
    if (ok) [gCurrentRenderer recomputeGradients];
    return ok;
}

void recalcSubGL(NII_PREFS* prefs, THIS_UINT8 *img8bit, tRGBAlut lut)
//makes a volume with size Sz1*kSz2*kSz3 voxels
{
    //glDeleteTextures(1,&prefs->intensityTexture3D);
    uint32_t *data = new uint32_t[prefs->voxelDim[1]*prefs->voxelDim[2]*prefs->voxelDim[3]]; //*4 as RGBA
    uint32_t *ptr = data;
    for (size_t i = 0; i < (prefs->voxelDim[1]*prefs->voxelDim[2]*prefs->voxelDim[3]); i++)
        *ptr++ = lut[img8bit[i]];
        //clock_t start = clock();
#ifdef MY_DEBUG //from nii_io.h
    NSDate *methodStart = [NSDate date];
#endif
    blendOverlays(prefs, data);
#ifdef MY_DEBUG //from nii_io.h
    NSLog(@"blendSec = %f", [[NSDate date] timeIntervalSinceDate:methodStart]);
#endif
    niiMetalUploadVolumeToCurrent(prefs, data); // per-window Metal renderer (uploads + recomputes gradients)
    delete[] data;
}

void rescaleRGBA(NII_PREFS* prefs, uint32_t *rawdata)
{
    //create look up table...
    long lut[256];
    int min = round(prefs->viewMin);
    int max = round(prefs->viewMax);
    if (min > max) {
        min = prefs->viewMax;
        max = prefs->viewMin;
    }
    #define MY_GAIN //#undef MY_GAIN //
    #ifdef MY_GAIN //Ken Perlin’s bias http://blog.demofox.org/2012/09/24/bias-and-gain-are-your-friend/
    float bias = 0.5;
    if ((prefs->fullMax > prefs->fullMin) && (max > min))
        bias = 0.5 * ((max-min)/ (prefs->fullMax - prefs->fullMin));
    bias = 1.0 - bias;
    if (bias <= 0.0) bias = 0.001;
    if (bias >= 1.0) bias = 0.999;
    for (int i = 0; i < 256; i++) {
        float v = (float)i/255.0;
        v = (v/ ((((1/bias) - 2)*(1 - v))+1));
        //if (i == 32) NSLog(@"-bias %g in %d out %g", bias, i, v);
        if (v > 1.0) v = 1.0;
        if (v < 0.0) v = 0.0;
        //if (i == 32) NSLog(@"bias %g in %d out %g", bias, i, round(v*255.0));
        lut[i] = round(255.0 * v);
    } //for all indices
    #else
    float slope = 255.0f/(max - min);
    for (int i = 0; i < 256; i++) {
        if (i <= min)
            lut[i] = 0;
        else if (i >= max)
            lut[i] = 255;
        else
            lut[i] = round((i-min)*slope);
    } //for all indices
    #endif
    //rescale volume with table...
    size_t nbytes = prefs->voxelDim[1]*prefs->voxelDim[2]*prefs->voxelDim[3]*4;//*4 as RGBA
    THIS_UINT8 *rawptr = (THIS_UINT8 *)rawdata;
    THIS_UINT8 *data = (THIS_UINT8 *) malloc(nbytes);
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"nii_img 4 malloc size %ld",nbytes);
    #endif
    THIS_UINT8 *ptr = data;
    //for (size_t i = 0; i < nbytes; i++)
    //    *ptr++ = lut[ *rawptr++];
    //for (size_t i = 0; i < nbytes; i++)
    //    *ptr++ = rand() % 256;
    nbytes = prefs->voxelDim[1]*prefs->voxelDim[2]*prefs->voxelDim[3];
    for (size_t i = 0; i < nbytes; i++) {
        *ptr++ = lut[ *rawptr++];//scale red
        *ptr++ = lut[ *rawptr++];//scale green
        *ptr++ = lut[ *rawptr++];//scale blue
        *ptr++ = *rawptr++; //leave alpha unchanged...
    }
  (void)data; // GL upload removed; Metal uploads the RGBA volume directly (recalcGL)

delete[] data;
}

// recalcSubRGBA (GL 3D-texture upload of an RGBA volume) removed — under Metal
// the RGBA volume is uploaded straight from recalcGL via niiMetalUploadVolumeToCurrent.


int recalcGL(FSLIO* fslio, NII_PREFS* prefs)
{
//    if ((fslio->niftiptr->dim[0] < 3) || (fslio->niftiptr->dim[0] >4)) {
//        printf("nii_makergb: error only 3D and 4D data supported");
//        return EXIT_FAILURE;
//    }
    if (prefs->numVox3D < 1) {//(fslio->niftiptr->nvox < 1) {
        printf("nii_makergb: voxels not loaded!");
        return EXIT_FAILURE;
    }
     if ((fslio->niftiptr->intent_code == NIFTI_INTENT_LABEL) && (fslio->niftiptr->datatype == NIFTI_TYPE_UINT8)) {
         if (fslio->niftiptr->isCustomLUT) {
             for (int i = 1; i <= 255; i++)
                 prefs->lut[i] = fslio->niftiptr->lut[i];
             float saturationFrac = fabs(prefs->viewMax-prefs->viewMin)/100;
             if ((saturationFrac >= 0) && (saturationFrac <= 1.0))
                 for (int i = 1; i <= 255; i++)
                     prefs->lut[i] = desaturateRGBA(prefs->lut[i], saturationFrac);
        } else
            createlutLabel(prefs->colorScheme, prefs->lut,fabs(prefs->viewMax-prefs->viewMin)/100 );
        THIS_UINT8 *raw8 = (THIS_UINT8 *) fslio->niftiptr->data;
        //prefs->lut[0] = makeRGBA(255*prefs->backColor[0],255* prefs->backColor[1],255*prefs->backColor[2],0);
        //if ( (prefs->lut[255] >> 24) == 0)
        //     prefs->lut[255] = prefs->lut[0];
         recalcSubGL(prefs,raw8, prefs->lut);
        return EXIT_SUCCESS;
    }
#ifdef MY_DEBUG
    NSDate *methodStart = [NSDate date];
#endif
    if ((fslio->niftiptr->intent_code == NIFTI_INTENT_LABEL) &&(fslio->niftiptr->datatype == NIFTI_TYPE_INT16)) {
        createlutLabel(prefs->colorScheme, prefs->lut, fabs(prefs->viewMax-prefs->viewMin)/100 );
        prefs->lut[0] = makeRGBA(255*prefs->backColor[0],255* prefs->backColor[1],255*prefs->backColor[2],0);
        THIS_UINT8 *img8bit = (THIS_UINT8 *) malloc(prefs->voxelDim[1]*prefs->voxelDim[2]*prefs->voxelDim[3]);
        size_t volOffset = prefs->currentVolume;
        if ((volOffset < 1) || (volOffset > prefs->numVolumes))
            volOffset = 1;
        volOffset = prefs->numVox3D* (volOffset-1);
        rescale16to8bit(fslio->niftiptr->data, prefs->numVox3D, volOffset, fslio->niftiptr->datatype, img8bit);
        recalcSubGL(prefs,img8bit, prefs->lut);
        free(img8bit);
        return EXIT_SUCCESS;
    }
    createlut(prefs->colorScheme, prefs->lut, prefs->lut_bias);
    //prefs->lut[0] =  makeRGBA(255*prefs->backColor[0],255* prefs->backColor[1],255*prefs->backColor[2],0);
    //if ( (prefs->lut[255] >> 24) == 0)
    //    prefs->lut[255] = prefs->lut[0];
    //NSLog(@"Alpha %d", (prefs->lut[255] >> 24));
    //lut[255] = (0 << 0)+ (255 << 8) + (0 << 16) + (0 << 24);
    //prefs->lut[255] = makeRGBA(255*prefs->backColor[0],255* prefs->backColor[1],255*prefs->backColor[2],0);
    #ifdef MY_DEBUG //from nii_io.h
    printf("makergb: volume size %dx%dx%d\n",prefs->voxelDim[1],prefs->voxelDim[2],prefs->voxelDim[3]);
    #endif
    double minRaw = nii_cal2raw(fslio->niftiptr-> scl_inter, fslio->niftiptr-> scl_slope, prefs->viewMin);
    double maxRaw = nii_cal2raw(fslio->niftiptr-> scl_inter, fslio->niftiptr-> scl_slope, prefs->viewMax);
    if (fslio->niftiptr->datatype == DT_RGBA32) {
        uint32_t *data = (uint32_t *) fslio->niftiptr->data;
        niiMetalUploadVolumeToCurrent(prefs, data); // per-window Metal renderer (RGB)
    } else {
        THIS_UINT8 *img8bit = (THIS_UINT8 *) malloc(prefs->voxelDim[1]*prefs->voxelDim[2]*prefs->voxelDim[3]);
        size_t volOffset = prefs->currentVolume;
        if ((volOffset < 1) || (volOffset > prefs->numVolumes))
            volOffset = 1;
        volOffset = prefs->numVox3D* (volOffset-1);
        rescale8bit(fslio->niftiptr->data, prefs->numVox3D, volOffset, fslio->niftiptr->datatype, minRaw, maxRaw, img8bit);
        cacheBackground8bit(prefs, img8bit); //lets updateStreamingOverlay skip this pass
        recalcSubGL(prefs,img8bit, prefs->lut);
        free(img8bit);
    }
    // (matcap is loaded once per renderer via NIIMetalRenderer loadMatcapFromBundle)
#ifdef MY_DEBUG
    NSLog(@"recalcGL_Sec = %f", [[NSDate date] timeIntervalSinceDate:methodStart]);
#endif
    return EXIT_SUCCESS;
}

-(bool) isBackgroundRGB
{
    return (fslio->niftiptr->datatype == DT_RGBA32);
}

bool checkMat (mat44 mat)
//see if Matrix is plausible - each row must have at least one non-zero cell
{
    if ((mat.m[0][0] == 0) && (mat.m[0][1] == 0) && (mat.m[0][2] == 0)) return FALSE;
    if ((mat.m[1][0] == 0) && (mat.m[1][1] == 0) && (mat.m[1][2] == 0)) return FALSE;
    if ((mat.m[2][0] == 0) && (mat.m[2][1] == 0) && (mat.m[2][2] == 0)) return FALSE;
    return TRUE;
}

void fix_sform (FSLIO* fslio)
//ensure matrix in sform is plausible
{
    bool sformOK = checkMat(fslio->niftiptr->sto_xyz);
    if ((sformOK) && (fslio->niftiptr->sform_code != 0)) return; //use original sform....
    bool qformOK = checkMat(fslio->niftiptr->qto_xyz);
    if ((qformOK) && (fslio->niftiptr->qform_code != 0)) { //substitute qform
        fslio->niftiptr->sto_xyz = fslio->niftiptr->qto_xyz;
        fslio->niftiptr->sto_ijk = fslio->niftiptr->qto_ijk;
        return;
    }
    if (sformOK) return; //use sform even though sform_code ==0 !
    //NSLog( @" q-mat %@", matToTextX (fslio->niftiptr->qto_xyz));
    if (qformOK) { //substitute qform even though qform_code ==0 !
        fslio->niftiptr->sto_xyz = fslio->niftiptr->qto_xyz;
        fslio->niftiptr->sto_ijk = fslio->niftiptr->qto_ijk;
        return;
    }
    //now we are getting desperate - lets use 'the "old" way' from nifti1.h
    mat44 m_toxyz;
    LOAD_MAT44(m_toxyz,fslio->niftiptr->pixdim[1],0,0,0, 0, fslio->niftiptr->pixdim[2],0,0, 0,0,fslio->niftiptr->pixdim[3], 0);

    if ((fslio->niftiptr->pixdim[1] ==0) || (fslio->niftiptr->pixdim[2] ==0) || (fslio->niftiptr->pixdim[3] ==0))
        LOAD_MAT44(m_toxyz,1,0,0,0, 0,1,0,0, 0,0,1,0);
        //m_toxyz = setMat44(1,0,0,0, 0,1,0,0, 0,0,1,0);
    mat44 m_toijk = nifti_mat44_inverse( m_toxyz ) ;
    fslio->niftiptr->sto_xyz = m_toxyz;
    fslio->niftiptr->sto_ijk = m_toijk;
}

void nii_setOrthoFSL (FSLIO* f){

    if (f->niftiptr->sform_code == NIFTI_XFORM_UNKNOWN) {
        return;
    }
    if (isMat44Canonical( f->niftiptr->sto_xyz)) {
        //NSLog( @" already canonical");
        return;
    }
    //copy fsl header to nifti header
    struct nifti_1_header h;
    for (int i = 0; i < 8; i++) h.dim[i] = f->niftiptr->dim[i];
    for (int i = 0; i < 8; i++) h.pixdim[i] = f->niftiptr->pixdim[i];
    mat2sForm(&h,f->niftiptr->sto_xyz);
    h.datatype = f->niftiptr->datatype ;
    h.sform_code = f->niftiptr->sform_code;
    h.bitpix = f->niftiptr->nbyper * 8;
    unsigned char *imgM = (unsigned char *) f->niftiptr->data;
    nii_setOrtho(imgM,&h);
    //  NSLog(@"%g %g %g",h.srow_x[0],h.srow_x[1],h.srow_x[2]);
    //convert dimensions 1-3 from NIfTI back to FSLIO, also convert spatial transforms (qform & sform)
    f->niftiptr->nx   = f->niftiptr->dim[1] = h.dim[1];
    f->niftiptr->ny   = f->niftiptr->dim[2] = h.dim[2];
    f->niftiptr->nz   = f->niftiptr->dim[3] = h.dim[3];
    f->niftiptr->dx = f->niftiptr->pixdim[1] = h.pixdim[1] ;
    f->niftiptr->dy = f->niftiptr->pixdim[2] = h.pixdim[2] ;
    f->niftiptr->dz = f->niftiptr->pixdim[3] = h.pixdim[3] ;
    f->niftiptr->sto_xyz.m[0][0] = h.srow_x[0] ;
    f->niftiptr->sto_xyz.m[0][1] = h.srow_x[1] ;
    f->niftiptr->sto_xyz.m[0][2] = h.srow_x[2] ;
    f->niftiptr->sto_xyz.m[0][3] = h.srow_x[3] ;
    f->niftiptr->sto_xyz.m[1][0] = h.srow_y[0] ;
    f->niftiptr->sto_xyz.m[1][1] = h.srow_y[1] ;
    f->niftiptr->sto_xyz.m[1][2] = h.srow_y[2] ;
    f->niftiptr->sto_xyz.m[1][3] = h.srow_y[3] ;
    f->niftiptr->sto_xyz.m[2][0] = h.srow_z[0] ;
    f->niftiptr->sto_xyz.m[2][1] = h.srow_z[1] ;
    f->niftiptr->sto_xyz.m[2][2] = h.srow_z[2] ;
    f->niftiptr->sto_xyz.m[2][3] = h.srow_z[3] ;
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            f->niftiptr->qto_xyz.m[i][j] = f->niftiptr->sto_xyz.m[i][j];
    f->niftiptr->sto_ijk = nifti_mat44_inverse( f->niftiptr->sto_xyz ) ;
    f->niftiptr->qto_ijk = nifti_mat44_inverse( f->niftiptr->qto_xyz ) ;
}

int nii_setup(FSLIO* fslio, NII_PREFS* prefs)
{
    //NSLog( @" q-mat %@", matToTextX (fslio->niftiptr->qto_xyz));
    fix_sform (fslio);
    prefs->numDtiV = 0;
    prefs->numVox3D = 1;
    for (int dim = 1; dim < 4; dim++)
        if (abs(fslio->niftiptr->dim[dim]) > 1)
            prefs->numVox3D = prefs->numVox3D * fslio->niftiptr->dim[dim];
    prefs->mouseIntensity = 0;
    prefs->mouseDownX = -1; //impossible!
    strcpy( prefs->nii_prefs_fname, "" );
    prefs->numVolumes = 1;
    prefs->currentVolume = 1;
    for (int dim = 4; dim < 8; dim++)
        if (fslio->niftiptr->dim[dim] > 1)
            prefs->numVolumes = prefs->numVolumes * fslio->niftiptr->dim[dim];
    int ret = nii_unify_datatype(fslio); //convert unusual formats to single precision datatype
    if (ret != EXIT_SUCCESS) {
        NSLog(@"nii_unify_datatype failed");
        setLoadDummy(fslio, prefs);
        return EXIT_FAILURE;
    }
    if (prefs->orthoOrient)
        nii_setOrthoFSL (fslio);
    else
        fslio->niftiptr->sform_code = NIFTI_XFORM_UNKNOWN; //unknown orientation, do not place L/R A/P S/I labels
    ret = nii_findrange(fslio, prefs);
    if (ret != EXIT_SUCCESS) return EXIT_FAILURE;
    for (long dim = 1; dim < 4; dim++) {
        prefs->voxelDim[dim] = fslio->niftiptr->dim[dim];
        prefs->fieldOfViewMM[dim] = fabs(fslio->niftiptr->dim[dim]*fslio->niftiptr->pixdim[dim]);
    }
    //NSLog(@"a %f -> %f",prefs->fullMin, prefs->fullMax);

    //NSLog(@"pxDim %g %g %g",fslio->niftiptr->pixdim[1], fslio->niftiptr->pixdim[2], fslio->niftiptr->pixdim[2]);
    //NSLog(@"voxDim %d %d %d",fslio->niftiptr->dim[1], fslio->niftiptr->dim[2], fslio->niftiptr->dim[2]);
    //NSLog(@"fovDim %g %g %g",prefs->fieldOfViewMM[1], prefs->fieldOfViewMM[2], prefs->fieldOfViewMM[3]);
    prefs->sto_ijk = fslio->niftiptr-> sto_ijk;
    prefs->sto_xyz = fslio->niftiptr-> sto_xyz;
    mm2frac (0,0,0, prefs);
    prefs->force_refreshGL = true;
    prefs->force_recalcGL = true;
    return ret;
}

// GL slice/crosshair draw helpers (drawXBar/drawSag/drawSagMirror/drawAx/
// drawCoro) and setRGBColor were removed in the Metal migration — the Metal
// renderer draws 2D slices, crosshairs and the mosaic itself (see
// NIIMetalRenderer encodeSliceAt:/encodeCrosshairs:/drawMosaicSliceOrient:).

float getMaxFloatXYZ(float v1, float v2, float v3)
{
    float ret;
    if ((v1 > v2) && (v1 > v3)) //v1 > v2, v1 > v3
        ret = v1;
    else if  (v2 > v3) //v2 > v3, v2 >= v1
        ret = v2;
    else //v3 >= v2, v3 >= v1
        ret = v3;
    return ret;
}

void scrnSizeX (NII_PREFS* prefs, CGPoint * imgSz)
{
    //NSLog(@"%g %g %g", prefs->fieldOfViewMM[1], prefs->fieldOfViewMM[2], prefs->fieldOfViewMM[3]);
    if ((prefs->scrnHt < 1) || (prefs->scrnWid < 1) || (prefs->fieldOfViewMM[1] <= 0.0) || (prefs->fieldOfViewMM[2] <= 0.0) || (prefs->fieldOfViewMM[3] <= 0.0) ) return;
    double mmPerPix = prefs->scrnWid/(prefs->fieldOfViewMM[1]+prefs->fieldOfViewMM[2]);
    double HmmPerPix = prefs->scrnHt/(prefs->fieldOfViewMM[2]+prefs->fieldOfViewMM[3]);
    prefs->scrnWideLayout = false;
    //NSLog(@"%gx%gx%g -", prefs->fieldOfViewMM[1], prefs->fieldOfViewMM[2], prefs->fieldOfViewMM[3]);
    switch (prefs->displayModeGL) {
        case   GL_2D_AXIAL:
            mmPerPix = prefs->scrnWid/prefs->fieldOfViewMM[1];
            HmmPerPix = prefs->scrnHt/prefs->fieldOfViewMM[2];
            if (mmPerPix > HmmPerPix) mmPerPix = HmmPerPix;
            prefs->scrnDim[1] = round(prefs->fieldOfViewMM[1]*mmPerPix);
            prefs->scrnDim[2] = round(prefs->fieldOfViewMM[2]*mmPerPix);
            imgSz->x = prefs->scrnDim[1]; //axial slice X is horizontal
            imgSz->y = prefs->scrnDim[2]; //axial slice Y is vertical
            prefs->mmPerPix = mmPerPix;
            return;
        case  GL_2D_CORONAL:
            mmPerPix = prefs->scrnWid/prefs->fieldOfViewMM[1];
            HmmPerPix = prefs->scrnHt/prefs->fieldOfViewMM[3];
            if (mmPerPix > HmmPerPix) mmPerPix = HmmPerPix;
            prefs->scrnDim[1] = round(prefs->fieldOfViewMM[1]*mmPerPix);
            prefs->scrnDim[3] = round(prefs->fieldOfViewMM[3]*mmPerPix);
            imgSz->x = prefs->scrnDim[1]; //coronal slice X is horizontal
            imgSz->y = prefs->scrnDim[3]; //coronal slice Z is vertical
            prefs->mmPerPix = mmPerPix;
            return;
        case   GL_2D_SAGITTAL:
            mmPerPix = prefs->scrnWid/prefs->fieldOfViewMM[2];
            HmmPerPix = prefs->scrnHt/prefs->fieldOfViewMM[3];
            if (mmPerPix > HmmPerPix) mmPerPix = HmmPerPix;
            prefs->scrnDim[2] = round(prefs->fieldOfViewMM[2]*mmPerPix);
            prefs->scrnDim[3] = round(prefs->fieldOfViewMM[3]*mmPerPix);
            imgSz->x = prefs->scrnDim[2]; //sagittal slice Y is horizontal
            imgSz->y = prefs->scrnDim[3]; //sagittal slice Z is vertical
            prefs->mmPerPix = mmPerPix;
            return;
            //break;
    }
    if (mmPerPix > HmmPerPix) mmPerPix = HmmPerPix;
    if ((prefs->displayModeGL == GL_2D_AND_3D) || (prefs->displayModeGL == GL_2D_ONLY))  { // GL_2D_AND_3D GL_2D_ONLY
        double mmMax = getMaxFloatXYZ(prefs->fieldOfViewMM[1], prefs->fieldOfViewMM[2], prefs->fieldOfViewMM[3]);
        double Hmm = prefs->fieldOfViewMM[1] + prefs->fieldOfViewMM[1] + prefs->fieldOfViewMM[2]; //Axial + Coronal + Sagittal
        if (prefs->displayModeGL == GL_2D_AND_3D) Hmm = Hmm + mmMax;
        Hmm = prefs->scrnWid/Hmm; //mmPerPix horizontal
        double Vmm = mmMax;

        Vmm = prefs->scrnHt/Vmm; //mmPerPix vertical
        if (Vmm > Hmm) Vmm = Hmm;
        //NSLog(@" %g %g", mmPerPix, Vmm );
        if (mmPerPix < Vmm) { //we can show larger images by having one row instead of two
            mmPerPix = Vmm;
            prefs->scrnWideLayout = true;
        }
    }
    prefs->scrnDim[1] = round(prefs->fieldOfViewMM[1]*mmPerPix);
    prefs->scrnDim[2] = round(prefs->fieldOfViewMM[2]*mmPerPix);
    prefs->scrnDim[3] = round(prefs->fieldOfViewMM[3]*mmPerPix);
    prefs->mmPerPix = mmPerPix;
    #ifdef NII_IMG_RENDER //defined in nii_definetypes.h
    prefs->renderBottom = 0;
    if (prefs->displayModeGL == GL_3D_ONLY) {
        prefs->renderLeft = 0;
        prefs->renderHt = prefs->scrnHt;//height;
        prefs->renderWid = prefs->scrnWid;//width;
        int renderPix = prefs->scrnHt;
        if (renderPix > prefs->scrnWid) renderPix = prefs->scrnWid;
        imgSz->x = renderPix;
        imgSz->y = renderPix;
    } else {
        if (prefs->scrnWideLayout) {
            prefs->renderLeft = prefs->scrnDim[1]+prefs->scrnDim[1]+prefs->scrnDim[2];
            //prefs->renderLeft = 0;//2*prefs->scrnDim[1];
            int renderPix = prefs->scrnWid - prefs->renderLeft;
            if (prefs->scrnHt < renderPix) renderPix = prefs->scrnHt;
            prefs->renderHt = renderPix;//height;
            prefs->renderWid = renderPix;//width;
            imgSz->x = prefs->scrnDim[1]+prefs->scrnDim[1]+prefs->scrnDim[2];
            imgSz->y = prefs->scrnDim[2]; //axial slice Y is vertical
            if (imgSz->y < prefs->scrnDim[3]) imgSz->y = prefs->scrnDim[3]; //coronal/sag slice Z is vertical
            if (prefs->displayModeGL == GL_2D_AND_3D) {
                imgSz->x = imgSz->x + renderPix;
                if (imgSz->y < renderPix) imgSz->y = renderPix; //rendering is largest image in vertical dimension
            }
        } else {
            prefs->renderLeft = prefs->scrnDim[1];
            prefs->renderHt = prefs->scrnDim[2];//height;
            prefs->renderWid = prefs->scrnDim[2];//width;
            imgSz->x = prefs->scrnDim[1]+prefs->scrnDim[2];
            imgSz->y = prefs->scrnDim[3]+prefs->scrnDim[2];
        }
    }
    #endif
    //NSLog(@"%gx%gx%g -> %dx%dx%d %gmm/pix", prefs->fieldOfViewMM[1], prefs->fieldOfViewMM[2], prefs->fieldOfViewMM[3], prefs->scrnDim[1], prefs->scrnDim[2], prefs->scrnDim[3], mmPerPix);

}

void scrnSize (NII_PREFS* prefs) {
    CGPoint imgSz = {0.0f, 0.0f}; //initialize to avoid compiler warning - set in scrnSizeX
    scrnSizeX (prefs, &imgSz);
    if ((prefs->scrnWid- imgSz.x) < (prefs->scrnHt - imgSz.y)) {
        //NSLog(@"top %g %g",imgSz.x, imgSz.y);
        prefs->colorBarPos[0] = 0.05; //left
        prefs->colorBarPos[1] = 0.96;//bottom
        prefs->colorBarPos[2] = 0.95;  //right
        prefs->colorBarPos[3] = 0.99;  //top
    } else {
        //NSLog(@"right %g %g",imgSz.x, imgSz.y);
        prefs->colorBarPos[0] = 0.96; //left
        prefs->colorBarPos[1] = 0.125;//bottom
        prefs->colorBarPos[2] = 0.99;  //right
        prefs->colorBarPos[3] = 0.98;  //top
    }
}

float  defuzzz(float x)
{
    if (fabs(x) < 1.0E-6) return 0.0;
    return x;
}

double getOverlayVoxelIntensity(long long vox, int overlayIndex, NII_PREFS* prefs)
{
    if (prefs->overlays[overlayIndex].datatype == NIFTI_TYPE_RGBA32) {
        // Y = 0.299R + 0.587G + 0.114B
        THIS_UINT8 *inbuf = (THIS_UINT8 *) prefs->overlays[overlayIndex].data;
        vox = ((vox-1)*4); //saved as RGBA quads (RGBARGBA), indexed from 0
        return  roundf ((inbuf[vox]*0.299)+(inbuf[vox+1]*0.587)+(inbuf[vox+2]*0.114));
        //prefs->mouseIntensity = (inbuf[vox]*0.299)+(inbuf[vox+prefs->numVox3D]*0.587)+(inbuf[vox+2*prefs->numVox3D]*0.114);
    } else if ( prefs->overlays[overlayIndex].datatype == NIFTI_TYPE_UINT8) {
        THIS_UINT8 *inbuf = (THIS_UINT8 *) prefs->overlays[overlayIndex].data;
        return (inbuf[vox]*prefs->overlays[overlayIndex].scl_slope)+prefs->overlays[overlayIndex].scl_inter;
    } else if ( prefs->overlays[overlayIndex].datatype == NIFTI_TYPE_INT16) {
        THIS_INT16 *inbuf = (THIS_INT16 *) prefs->overlays[overlayIndex].data;
        return (inbuf[vox]*prefs->overlays[overlayIndex].scl_slope)+prefs->overlays[overlayIndex].scl_inter;
    } else {
        SCALED_IMGDATA *inbuf = (SCALED_IMGDATA *) prefs->overlays[overlayIndex].data;
        return(inbuf[vox]*prefs->overlays[overlayIndex].scl_slope)+prefs->overlays[overlayIndex].scl_inter;
    }
}

- (NSString *) getIntensityStr
{
    NSString *result = @"";
    if (prefs->currentVolume > prefs->numVolumes)
        return result;
    int slice[3];
    if ((prefs->voxelDim[1] < 1) || (prefs->voxelDim[2] < 1) || (prefs->voxelDim[3] < 1) ) return result;
    mat44 R = prefs->sto_ijk;
    for (int i = 0; i < 3; i++) {
        slice[i] = round( (R.m[i][0]*prefs->mm[1])+(R.m[i][1]*prefs->mm[2])+ (R.m[i][2]*prefs->mm[3])+R.m[i][3] );
        if (slice[i] < 0) slice[i] = 0;
        if (slice[i] >= prefs->voxelDim[i+1]) slice[i] = prefs->voxelDim[i+1]-1;
    }
    long long vox = slice[0] + (slice[1]*prefs->voxelDim[1])+(slice[2]*prefs->voxelDim[1]*prefs->voxelDim[2]);
    if (fslio->niftiptr->datatype != NIFTI_TYPE_RGBA32)
        vox = vox + ((prefs->currentVolume-1) * prefs->numVox3D);
    float y = getVoxelIntensity(vox, fslio);
    if ( (fslio->niftiptr->intent_code == NIFTI_INTENT_LABEL) && (y <= [labelArray count]) && (y >= 1)  )
        result = [NSString stringWithFormat:@"%@", labelArray[(int)round(y)] ];
    else
        result = [NSString stringWithFormat:@"%g", defuzzz(y) ];
    //result = [result stringByAppendingString:[NSString stringWithFormat:@"%g", defuzzz(i) ]];
    for (int i = 0; i < MAX_OVERLAY; i++) {
        if (prefs->overlays[i].datatype != DT_NONE) {
            y = getOverlayVoxelIntensity(vox, i, prefs);
            result = [result stringByAppendingString:[NSString stringWithFormat:@",%g", defuzzz(y) ]];
        }
    }//for each overlay
    return result;
}


double Slicemm2frac (double mm, int orient, NII_PREFS* prefs) {
    if ((prefs->voxelDim[1] < 1) || (prefs->voxelDim[2] < 1) || (prefs->voxelDim[3] < 1) ) return 0.5;
    mat44 R = prefs->sto_ijk;
    double sliceFrac[4] = {0,0,0,0};
    double sliceMM[4] = {0,0,0,0};
    if (orient == 1) //axial
        sliceMM[3] = mm;
    else if (orient == 2) //coronal
        sliceMM[2] = mm;
    else //sagittal of sagittal mirror
        sliceMM[1] = mm;
    for (int i = 0; i < 3; i++) {
        sliceFrac[i+1] = round( (R.m[i][0]*sliceMM[1])+(R.m[i][1]*sliceMM[2])+ (R.m[i][2]*sliceMM[3])+R.m[i][3] )/prefs->voxelDim[i+1];
        if ((sliceFrac[i+1] < 0) || (sliceFrac[i+1]> 1)) sliceFrac[i+1] = 0.5;
    }
    if (prefs->viewRadiological) sliceFrac[1] = 1.0 - sliceFrac[1];  //test!!!
    if (orient == 1) //axial
        return sliceFrac[3];
    else if (orient == 2) //coronal
        return sliceFrac[2];
    else //sagittal or sagittal mirror
        return sliceFrac[1];
}

double  defuzzz(double x) {
    if (fabs(x) < 1.0E-6) return 0.0;
    return x;
}


// Metal counterpart of redrawMosaic + makeMosaic's GL-FBO readback: render the
// slice montage offscreen into the per-window renderer, read it back (top-origin
// RGBA) and copy the image to the clipboard. Reuses the renderer's already-
// uploaded intensity volume (no recalcGL needed — the same voxels, new slices).
- (void) makeMosaicMetal:(mosaicObj*)mos width:(int)width height:(int)height {
    NIIMetalRenderer *r = (NIIMetalRenderer *)_metalRenderer;
    if (!r || ![r beginMosaicFrameWidth:width height:height prefs:prefs]) return;
    // Pass order matches redrawMosaic: rows/cols ascending for positive overlap,
    // descending for negative, so later cells overwrite earlier ones identically.
    int rInc = 1, rStart = 1, rEnd = kMaxMosaicDim;
    if (mos->VOverlap < 0) { rStart = kMaxMosaicDim-1; rEnd = 0; rInc = -1; }
    int cInc = 1, cStart = 1, cEnd = kMaxMosaicDim;
    if (mos->HOverlap < 0) { cStart = kMaxMosaicDim-1; cEnd = 0; cInc = -1; }
    for (int row = rStart; row != rEnd; row += rInc) {
        for (int c = cStart; c != cEnd; c += cInc) {
            int orient = mos->Orient[row][c];
            if (orient < 1) continue;
            double sliceFrac1 = mos->Slice[row][c];
            if (mos->SliceIsMM)
                sliceFrac1 = Slicemm2frac(sliceFrac1, orient, prefs);
            double sliceFrac[4] = {0,0,0,0};
            if (orient == 1)      sliceFrac[3] = sliceFrac1; // axial
            else if (orient == 2) sliceFrac[2] = sliceFrac1; // coronal
            else                  sliceFrac[1] = sliceFrac1; // sagittal / mirror
            [r drawMosaicSliceOrient:orient
                                   x:round(mos->Pos[row][c].x) y:round(mos->Pos[row][c].y)
                                   w:(orient == 1 || orient == 2) ? prefs->voxelDim[1] : prefs->voxelDim[2]
                                   h:(orient == 1) ? prefs->voxelDim[2] : prefs->voxelDim[3]
                           sliceFrac:sliceFrac prefs:prefs];
        }
    }
    // Slice-position labels (second pass so they sit atop the slices).
    if (mos->isLabel) {
        id<MTLDevice> dev = r.device; // reuse the renderer's device (no per-draw device creation)
        CGFloat fs = niiBackingScale();
        float bgLum = (prefs->backColor[0] + prefs->backColor[1] + prefs->backColor[2]) / 3.0f;
        simd_float4 tint = (bgLum > 0.5f) ? (simd_float4){0,0,0,1} : (simd_float4){1,1,1,1};
        for (int row = rStart; row != rEnd; row += rInc) {
            for (int c = cStart; c != cEnd; c += cInc) {
                if (mos->Orient[row][c] < 1) continue;
                float wid = (mos->Orient[row][c] > 2) ? prefs->voxelDim[3] : prefs->voxelDim[1];
                float ht  = (mos->Orient[row][c] == 1) ? prefs->voxelDim[2] : prefs->voxelDim[3];
                NSString *str = [NSString stringWithFormat:@"%g", mos->Slice[row][c]];
                NIIMetalText *t = [[NIIMetalText alloc] initWithString:str pointSize:(14*fs) device:dev];
                if (t.texture) { // drawBelowPoint: centered, top at the point
                    float px = mos->Pos[row][c].x + wid/2.0f, py = mos->Pos[row][c].y + ht;
                    [r drawGlyphTexture:t.texture width:t.pixelWidth height:t.pixelHeight
                                    atX:(px - t.pixelWidth/2.0f) y:(py - t.pixelHeight) tint:tint];
                }
            }
        }
    }
    void *rgba = [r endOffscreenReadback];
    if (!rgba) return;
    // Readback is top-origin already (no CIImage flip needed, unlike the GL FBO).
#if TARGET_OS_OSX
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO
        isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:3*width bitsPerPixel:0];
    unsigned char *src = (unsigned char *)rgba, *dst = [rep bitmapData];
    for (int i = 0; i < width*height; i++) { dst[i*3]=src[i*4]; dst[i*3+1]=src[i*4+1]; dst[i*3+2]=src[i*4+2]; }
    free(rgba);
    NSImage *imag = [[NSImage alloc] init];
    [imag addRepresentation:rep];
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard writeObjects:[NSArray arrayWithObject:imag]];
#else
    // iOS/iPadOS: build a CGImage from the RGB readback and put a UIImage on the
    // system pasteboard. (CoreGraphics is shared; pasteboard/UIImage are UIKit.)
    unsigned char *rgb = (unsigned char *)malloc((size_t)width*height*3);
    if (!rgb) { free(rgba); return; }
    unsigned char *src = (unsigned char *)rgba;
    for (int i = 0; i < width*height; i++) { rgb[i*3]=src[i*4]; rgb[i*3+1]=src[i*4+1]; rgb[i*3+2]=src[i*4+2]; }
    free(rgba);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgb, width, height, 8, 3*width, cs, kCGImageAlphaNone);
    CGImageRef cg = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (cg) {
        UIImage *imag = [UIImage imageWithCGImage:cg];
        [UIPasteboard generalPasteboard].image = imag;
        CGImageRelease(cg);
    }
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(rgb);
#endif
}

-(void) makeMosaic:(NSString *)mosStr
{
    //NSString *str = @"V 0.5 H 0.5 0.5 S 0.3; C 0.1 0.7";
    mosaicObj *mos = [[mosaicObj alloc] init];
    [mos str2Mosaic:mosStr];
    [mos prepMosaic: prefs->voxelDim[1] Y: prefs->voxelDim[2] Z: prefs->voxelDim[3]];
    int width = mos->TotalSizeInPixels.x;
    int height = mos->TotalSizeInPixels.y;
    //NSLog(@"%d x %d", width, height);
    if((width <1) || (height <1)) return;
    [self makeMosaicMetal:mos width:width height:height];
    return;
} //makeMosaic

// Per-frame redraw: run recalcGL's CPU data-prep (LUT / RGBA build), which feeds
// the volume to the per-window renderer via the recalcSub* upload hooks, then
// render the full 2D+3D frame with Metal.
- (void) redrawMetalInView:(MTKView *)view {
    if ((prefs->scrnHt < 1) || (prefs->scrnWid < 1)) return;
    if (prefs->busyGL) return;
    prefs->busyGL = true;
    if (!_metalRenderer && view.device) {
        _metalRenderer = [NIIMetalRenderer offscreenRendererWithDevice:view.device libraryURL:nil];
        [(NIIMetalRenderer *)_metalRenderer loadMatcapFromBundle];
    }
    NIIMetalRenderer *r = (NIIMetalRenderer *)_metalRenderer;
    gCurrentRenderer = r; // recalc upload hooks feed THIS window's renderer
    if (prefs->force_overlayGL && !prefs->force_recalcGL) {
        // Streaming overlay update: re-compose just the changed box. Falls back to the
        // full rebuild if the cache or the textures are not in place yet.
        prefs->force_overlayGL = false;
        if (!refreshOverlayRegionGL(prefs)) prefs->force_recalcGL = true;
    }
    if (prefs->force_recalcGL) {
        prefs->force_recalcGL = false;
        prefs->force_overlayGL = false;
        recalcGL(fslio, prefs);
        scrnSize(prefs);
        #ifdef NII_IMG_RENDER
        recalcRender(prefs);
        #endif
    }
    if (r && [r beginFrameInView:view prefs:prefs]) {
        if (!self.is2D)
            [r drawOrientCubeForPrefs:prefs]; // 3D orientation indicator
        if (self.is2D || (prefs->displayModeGL == GL_2D_AND_3D))
            [self drawMetalOverlays:r];
        [r endFrameInView:view];
    }
    prefs->force_refreshGL = false;
    prefs->busyGL = false;
}

- (BOOL) metalScreenshotIntoRGB:(unsigned char *)dest width:(int)w height:(int)h {
    NIIMetalRenderer *r = (NIIMetalRenderer *)_metalRenderer;
    if (!r || w < 1 || h < 1) return NO;
    // Offscreen frame WITH overlays (orientation cube + 2D overlays), matching
    // the on-screen composition.
    if (![r beginOffscreenFrameWidth:w height:h prefs:prefs]) return NO;
    if (!self.is2D)
        [r drawOrientCubeForPrefs:prefs];
    if (self.is2D || (prefs->displayModeGL == GL_2D_AND_3D))
        [self drawMetalOverlays:r];
    void *rgba = [r endOffscreenReadback];
    if (!rgba) return NO;
    unsigned char *src = (unsigned char *)rgba;
    for (int i = 0; i < w*h; i++) { dest[i*3] = src[i*4]; dest[i*3+1] = src[i*4+1]; dest[i*3+2] = src[i*4+2]; }
    free(rgba);
    return YES;
}

// 2D overlays for the Metal frame (port of redraw2D's overlay section). Uses
// NIIMetalText (cross-platform GLString replacement). Drawn between begin/end.
- (void)drawMetalOverlays:(NIIMetalRenderer *)r {
    id<MTLDevice> dev = r.device; // reuse the renderer's device (no per-draw device creation)
    // Text is rasterized in drawable (backing) pixels; scale point sizes by the
    // backing factor so they aren't tiny on Retina (plus a bump for readability).
    CGFloat fs = niiBackingScale();
    CGFloat fLabel = 18 * fs, fOrient = 24 * fs, fBar = 15 * fs;
    // Contrast the label with the background (white text is invisible on white).
    float bgLum = (prefs->backColor[0] + prefs->backColor[1] + prefs->backColor[2]) / 3.0f;
    simd_float4 white = (bgLum > 0.5f) ? (simd_float4){0, 0, 0, 1} : (simd_float4){1, 1, 1, 1};
    if (prefs->showInfo) {
        NSString *intensityStr = [self getIntensityStr];
        NSString *s;
        if (prefs->numVolumes < 2)
            s = [NSString stringWithFormat:@"%g×%g×%g=%@", defuzzz(prefs->mm[1]), defuzzz(prefs->mm[2]), defuzzz(prefs->mm[3]), intensityStr];
        else
            s = [NSString stringWithFormat:@"%g×%g×%g=%@ %d/%d", defuzzz(prefs->mm[1]), defuzzz(prefs->mm[2]), defuzzz(prefs->mm[3]), intensityStr, prefs->currentVolume, prefs->numVolumes];
        NIIMetalText *t = [[NIIMetalText alloc] initWithString:s pointSize:fLabel device:dev];
        if (t.texture) // drawAboveLeftOfPoint(scrnWid-8, 4): bottom-right near the point
            [r drawGlyphTexture:t.texture width:t.pixelWidth height:t.pixelHeight
                            atX:(prefs->scrnWid - 8 - t.pixelWidth) y:4 tint:white];
    }
    // Orientation labels (port of drawOrientLabelTex). drawRightOfPoint -> left
    // edge at px, vertically centered; drawBelowPoint -> centered, top at py.
    if (prefs->showOrient && prefs->scrnDim[1] >= 16 && fslio
        && fslio->niftiptr->sform_code != NIFTI_XFORM_UNKNOWN) {
        int d1 = prefs->scrnDim[1], d2 = prefs->scrnDim[2], d3 = prefs->scrnDim[3];
        NSString *lr = prefs->viewRadiological ? @"R" : @"L";
        void (^right)(NSString*,float,float) = ^(NSString *str, float px, float py){
            NIIMetalText *t = [[NIIMetalText alloc] initWithString:str pointSize:fOrient device:dev];
            if (t.texture) [r drawGlyphTexture:t.texture width:t.pixelWidth height:t.pixelHeight
                                           atX:px y:(py - t.pixelHeight/2.0f) tint:white];
        };
        void (^below)(NSString*,float,float) = ^(NSString *str, float px, float py){
            NIIMetalText *t = [[NIIMetalText alloc] initWithString:str pointSize:fOrient device:dev];
            if (t.texture) [r drawGlyphTexture:t.texture width:t.pixelWidth height:t.pixelHeight
                                           atX:(px - t.pixelWidth/2.0f) y:(py - t.pixelHeight) tint:white];
        };
        if (prefs->displayModeGL == GL_2D_AXIAL)      { right(lr, 8, d2/2.0f); }
        else if (prefs->displayModeGL == GL_2D_CORONAL) { right(lr, 8, d3/2.0f); }
        else if (prefs->displayModeGL == GL_2D_SAGITTAL) { /* none */ }
        else { // 2x2 / 3-up
            if (d2 > 16) right(lr, 8, d2/2.0f);                          // L/R on axial
            if (!prefs->scrnWideLayout && d3 > 16) right(lr, 8, d2 + d3/2.0f); // L/R on coronal
            if (d3 > 16) below(@"A", d1/2.0f, d2);                       // A on axial
            if (prefs->scrnWideLayout) {
                if (d3 > 16) right(lr, 8 + d1, d3/2.0f);
                if (d3 > 16) below(@"S", d1 + d1/2.0f, d3);
            } else if (d3 > 16) {
                below(@"S", d1/2.0f, d2 + d3);
            }
        }
    }
    // DTI vectors (port of drawVectors): 3 line segments, one per plane.
    if (prefs->numDtiV >= prefs->currentVolume && prefs->currentVolume >= 1) {
        float d1 = prefs->scrnDim[1], d2 = prefs->scrnDim[2], d3 = prefs->scrnDim[3];
        float mn = MIN(MIN(d1, d2), d3) / 2.0f;
        float vx = prefs->dtiV[prefs->currentVolume-1][0] * mn * (prefs->viewRadiological ? -1 : 1);
        float vy = prefs->dtiV[prefs->currentVolume-1][1] * mn;
        float vz = prefs->dtiV[prefs->currentVolume-1][2] * mn;
        float cx = d1/2, ax = d1/2, sx = d1 + d2/2;
        float coY = d2 + d3/2, axY = d2/2, saY = d2 + d3/2;
        float seg[12] = {
            cx + vx, coY + vz,  cx, coY,   // coronal
            ax + vx, axY + vy,  ax, axY,   // axial
            sx + vy, saY + vz,  sx, saY,   // sagittal
        };
        [r drawLines:seg count:6 color:(simd_float4){0.9f, 0.9f, 0.1f, 0.9f} width:5.0f]; // GL glLineWidth(5)
    }
    // Colorbar: gradient + numeric tick labels (port of drawColorBarTex). Gated like the GL path.
    if (prefs->showInfo && fslio && fslio->niftiptr->intent_code != NIFTI_INTENT_LABEL) {
        float L = prefs->colorBarPos[0]*prefs->scrnWid, B = prefs->colorBarPos[1]*prefs->scrnHt;
        float Rr = prefs->colorBarPos[2]*prefs->scrnWid, Tt = prefs->colorBarPos[3]*prefs->scrnHt;
        if (L > Rr) { float t=L; L=Rr; Rr=t; }
        if (B > Tt) { float t=B; B=Tt; Tt=t; }
        float lW = Rr-L, lH = Tt-B;
        if (lW > 2 && lH > 2) {
            const int N = 255;
            float *cv = (float *)malloc((size_t)N*6*7*sizeof(float));
            if (!cv) return;
            int p = 0;
            for (int i = 0; i < N; i++) {
                uint32_t clr = prefs->lut[i+1];
                float rr=(clr&0xff)/255.0f, gg=((clr>>8)&0xff)/255.0f, bb=((clr>>16)&0xff)/255.0f;
                float x0,y0,x1,y1;
                if (lH >= lW) { x0=L; x1=Rr; y0=B+lH*i/N; y1=B+lH*(i+1)/N; }
                else          { y0=B; y1=Tt; x0=L+lW*i/N; x1=L+lW*(i+1)/N; }
                float qx[6]={x0,x1,x1,x0,x1,x0}, qy[6]={y0,y0,y1,y0,y1,y1};
                for (int k=0;k<6;k++){ cv[p++]=qx[k]; cv[p++]=qy[k]; cv[p++]=0; cv[p++]=rr; cv[p++]=gg; cv[p++]=bb; cv[p++]=1; }
            }
            [r drawColoredVerts:cv count:N*6];
            free(cv);
            // Numeric tick labels along the bar (min..max), with a short tick mark.
            BOOL vertical = (lH >= lW);
            const float fracs[5] = {0.0f, 0.25f, 0.5f, 0.75f, 1.0f};
            for (int ti = 0; ti < 5; ti++) {
                float fr = fracs[ti];
                double val = prefs->viewMin + (prefs->viewMax - prefs->viewMin) * fr;
                NIIMetalText *lbl = [[NIIMetalText alloc] initWithString:[NSString stringWithFormat:@"%g", val]
                                                              pointSize:fBar device:dev];
                if (!lbl.texture) continue;
                float tx, ty;
                if (vertical) {
                    float y = B + lH * fr;
                    tx = L - lbl.pixelWidth - 6;
                    ty = y - lbl.pixelHeight * fr; // fr=0 bottom-aligned, fr=1 top-aligned
                    float tick[4] = { L - 5, y, L, y };
                    [r drawLines:tick count:2 color:white width:1.5f];
                } else {
                    float x = L + lW * fr;
                    tx = x - lbl.pixelWidth * fr;  // fr=0 left-aligned, fr=1 right-aligned
                    ty = B - lbl.pixelHeight - 6;
                    float tick[4] = { x, B - 5, x, B };
                    [r drawLines:tick count:2 color:white width:1.5f];
                }
                [r drawGlyphTexture:lbl.texture width:lbl.pixelWidth height:lbl.pixelHeight atX:tx y:ty tint:white];
            }
        }
    }
    // Histogram (port of drawHistogram) — 2D-only mode, in the empty quadrant.
    if (self.is2D && prefs->showInfo) {
        const int kB = 32;
        int Lft = prefs->scrnDim[1], Wid = prefs->scrnDim[2], Ht = prefs->scrnDim[2];
        int WidB = Wid - 2*kB, HtB = Ht - 2*kB;
        float ymax = 0;
        for (int i = 0; i < MAX_HISTO_BINS; i++) if (prefs->histo[i] > ymax) ymax = prefs->histo[i];
        if (WidB >= 4 && HtB >= 4 && ymax > 0) {
            ymax = logf(ymax);
            float cr=prefs->colorBarBorderColor[0], cg=prefs->colorBarBorderColor[1], cbb=prefs->colorBarBorderColor[2];
            const int N = MAX_HISTO_BINS;
            float *hv = (float *)malloc((size_t)(N-1)*6*7*sizeof(float)); if (!hv) return; int p = 0;
            for (int i = 0; i < N-1; i++) {
                float x0 = Lft+kB + (float)i/N*WidB, x1 = Lft+kB + (float)(i+1)/N*WidB;
                float y0 = prefs->histo[i]   > 0 ? logf(fabsf(prefs->histo[i]))  /ymax*HtB : 0; if (y0<1) y0=1;
                float y1 = prefs->histo[i+1] > 0 ? logf(fabsf(prefs->histo[i+1]))/ymax*HtB : 0; if (y1<1) y1=1;
                float b = kB;
                float qx[6]={x0,x0,x1,x0,x1,x1}, qy[6]={b,y0+b,y1+b,b,y1+b,b};
                for (int k=0;k<6;k++){ hv[p++]=qx[k]; hv[p++]=qy[k]; hv[p++]=0; hv[p++]=cr; hv[p++]=cg; hv[p++]=cbb; hv[p++]=0.9f; }
            }
            [r drawColoredVerts:hv count:(N-1)*6];
            free(hv);
        }
    }
}

// doRedraw was the OpenGL redraw entry point. Under Metal the view drives
// rendering through redrawMetalInView: (MTKView delegate), so this is now a
// no-op kept only to satisfy the declaration / any stray callers.
- (bool) doRedraw {
    return false;
}



/*int setZeros(FSLIO* fslio, NII_PREFS* prefs) {
    if (fslio->niftiptr->datatype != SCALED_IMGDATA_TYPE) return EXIT_FAILURE;
    if (prefs->fullMin <= -1000) return EXIT_FAILURE; //not for Hounsfield units
    if ((prefs->fullMin >= 0) || (prefs->fullMax < 0)) return EXIT_FAILURE; //only for images with positive and negative values
    long len3d = (long)  prefs->numVox3D;
    if ( len3d < 1) return EXIT_FAILURE;
    size_t volOffset = prefs->currentVolume;
    if ((volOffset < 1) || (volOffset > prefs->numVolumes))
        volOffset = 1;
    volOffset = prefs->numVox3D * (volOffset-1);
    SCALED_IMGDATA *img = (SCALED_IMGDATA *)fslio->niftiptr->data;
    //make sure a reasonable proportion of data is zero
    long nZero = 0;
    for (long vx = 0; vx < len3d; vx++)
        if (img[volOffset+vx] == 0) nZero ++;
    if (nZero < (len3d >> 4)) return EXIT_FAILURE; //at least 6.25% of voxels must be zero 1/(2^4) = 1/16
    //allocate mask memory
    SCALED_IMGDATA mn = prefs->fullMin;
    SCALED_IMGDATA *mask = (SCALED_IMGDATA *) malloc((size_t) len3d * sizeof(SCALED_IMGDATA));
    SCALED_IMGDATA *mask2 = (SCALED_IMGDATA *) malloc((size_t) len3d * sizeof(SCALED_IMGDATA));
    //create mask
    for (long vx = 0; vx < len3d; vx++)
        mask[vx] = img[volOffset+vx];
    //dilate mask
    long dx = 1;
    for (long vx = 0; vx < dx; vx++)
        mask2[vx] = 0;
    for (long vx = dx; vx < len3d; vx++)
        mask2[vx] = mask[vx-dx]; //left
    for (long vx = 0; vx < (len3d-dx); vx++)
        mask2[vx] += mask[vx+dx]; //right
    dx = prefs->voxelDim[1];
    for (long vx = dx; vx < len3d; vx++)
        mask2[vx] += mask[vx-dx]; //anterior
    for (long vx = 0; vx < (len3d-dx); vx++)
        mask2[vx] += mask[vx+dx]; //posterior
    dx = prefs->voxelDim[1]*prefs->voxelDim[2];
    for (long vx = dx; vx < len3d; vx++)
        mask2[vx] += mask[vx-dx]; //below
    for (long vx = 0; vx < (len3d-dx); vx++)
        mask2[vx] += mask[vx+dx]; //above
    //apply mask
    for (long vx = 0; vx < len3d; vx++)
        if (mask2[vx] == 0.0)
            img[volOffset+vx] = mn;
    //release mask
    free(mask);
    free(mask2);
    return EXIT_SUCCESS;
} //setZeros */

-(bool) removeHaze{
    if (prefs->numVox3D < 2) return FALSE; //only for volumes
    //if (prefs->numVolumes > 1) return FALSE; //only for 3D data - not 4D
    if (fslio->niftiptr->datatype == DT_RGBA32) return FALSE; //not for RGB data
    if (prefs->numVox3D != (prefs->voxelDim[1]*prefs->voxelDim[2]*prefs->voxelDim[3])) NSLog(@"Haze: We have a problem");
    //setZeros(fslio, prefs); // <- this was only for float images
    THIS_UINT8 *mask8bit = (THIS_UINT8 *) malloc(prefs->numVox3D);
    size_t volOffset = prefs->currentVolume;
    if ((volOffset < 1) || (volOffset > prefs->numVolumes))
        volOffset = 1;
    volOffset = prefs->numVox3D* (volOffset-1);
    double minRaw = nii_cal2raw(fslio->niftiptr-> scl_inter, fslio->niftiptr-> scl_slope, prefs->viewMin);
    double maxRaw = nii_cal2raw(fslio->niftiptr-> scl_inter, fslio->niftiptr-> scl_slope, prefs->viewMax);
    rescale8bit(fslio->niftiptr->data, prefs->numVox3D, volOffset, fslio->niftiptr->datatype, minRaw, maxRaw, mask8bit);
    //applyOtsuBinary (img8bit,(int) prefs->numVox3D, 5);
    //NSLog(@" Voxels %d x %d x %d", prefs->voxelDim[1], prefs->voxelDim[2], prefs->voxelDim[3]);
    //NSDate *startTime = [NSDate date];
    maskBackground  (mask8bit, prefs->voxelDim[1], prefs->voxelDim[2], prefs->voxelDim[3], 5,2, TRUE);
    //NSLog(@"Execution Time: %f", [[NSDate date] timeIntervalSinceDate:startTime]);
    if ( fslio->niftiptr->datatype == NIFTI_TYPE_UINT8) {
        THIS_UINT8 *inbuf = (THIS_UINT8 *) fslio->niftiptr->data;
        for (int i = 0; i < prefs->numVox3D; i++)
            if (mask8bit[i] == 0)
                inbuf[i+volOffset] = 0;
    } else if ( fslio->niftiptr->datatype == NIFTI_TYPE_INT16) {
        THIS_INT16 *inbuf = (THIS_INT16 *) fslio->niftiptr->data;
        THIS_INT16 min = round(nii_cal2raw(fslio->niftiptr-> scl_inter, fslio->niftiptr-> scl_slope, prefs->fullMin));
        for (int i = 0; i < prefs->numVox3D; i++)
            if (mask8bit[i] == 0)
                inbuf[i+volOffset] = min;
    } else {
        SCALED_IMGDATA *inbuf = (SCALED_IMGDATA *) fslio->niftiptr->data;
        SCALED_IMGDATA min = nii_cal2raw(fslio->niftiptr-> scl_inter, fslio->niftiptr-> scl_slope, prefs->fullMin);
        for (int i = 0; i < prefs->numVox3D; i++)
            if (mask8bit[i] == 0)
                inbuf[i+volOffset] = min;
    }
    free(mask8bit);
    prefs->force_refreshGL = true;
    prefs->force_recalcGL = true;
    return TRUE;
} //removeHaze()

-(bool) sharpen { //apply unsharp mask
    if (fslio->niftiptr->intent_code == NIFTI_INTENT_LABEL) return FALSE; //the border of Area 17 and 18 is NOT 16 or 19!!!
    if (fslio->niftiptr->datatype == DT_RGBA32) return FALSE; //not for RGB data
    int Xdim = prefs->voxelDim[1];
    int Ydim = prefs->voxelDim[2];
    int Zdim = prefs->voxelDim[3];
    size_t volOffset = prefs->currentVolume;
    if ((volOffset < 1) || (volOffset > prefs->numVolumes))
        volOffset = 1;
    volOffset = prefs->numVox3D* (volOffset-1);
    if ((Xdim < 5) || (Ydim < 5) || (Zdim < 5)) return FALSE;
    if (prefs->numVox3D != (prefs->voxelDim[1]*prefs->voxelDim[2]*prefs->voxelDim[3])) return FALSE; //only 3D
    int nvox = Xdim * Ydim * Zdim;
    //generate two cloned volumes of image data: sum, img
    //  we will do our calculation in floating point, so we need to convert 8/16-bit integer values to floats.
    SCALED_IMGDATA *img = new SCALED_IMGDATA[nvox]();
    if ( fslio->niftiptr->datatype == NIFTI_TYPE_UINT8) {
        THIS_UINT8 *inbuf = (THIS_UINT8 *) fslio->niftiptr->data;
        for (int i = 0; i < prefs->numVox3D; i++)
                img[i] = inbuf[i+volOffset];
    } else if ( fslio->niftiptr->datatype == NIFTI_TYPE_INT16) {
        THIS_INT16 *inbuf = (THIS_INT16 *) fslio->niftiptr->data;
        for (int i = 0; i < prefs->numVox3D; i++)
            img[i] = inbuf[i+volOffset];
    } else {
        SCALED_IMGDATA *inbuf = (SCALED_IMGDATA *) fslio->niftiptr->data;
        for (int i = 0; i < prefs->numVox3D; i++)
            img[i] = inbuf[i+volOffset];
    }
    SCALED_IMGDATA mn = img[0];
    SCALED_IMGDATA mx = img[0];
    for (int i = 0; i < prefs->numVox3D; i++) { //find min/max for volume - clip to avoid ringing in air
        if (img[i] > mx) mx = img[i];
        if (img[i] < mn) mn = img[i];
    }
    SCALED_IMGDATA *sum = new SCALED_IMGDATA[nvox]();
    memcpy (sum, img, nvox*sizeof(THIS_INT32)); //memcpy(destination, source)
    //we will emulate a Gaussian blur be weighting the center twice as much as immediate neighbors
    //  we will do this in each dimension separately (since Gaussian kernel is separable)
    //sum with left/right neighbors
    for (int i = 2; i < (nvox-2); i++)
        img[i] = sum[i-1] + sum[i] + sum[i] + sum[i+1];// left+2*center+right
    //sum result with anterior/posterior neighbors
    for (int i = Xdim; i < (nvox-Xdim-1); i++)
        sum[i] = img[i-Xdim] + img[i] + img[i] + img[i+Xdim];// anterior+2*center+posterior
    //sum with superior/inferior neighbors, generate output
    int sliceSz = Xdim*Ydim;
    //int sliceSz2 = sliceSz * 2;
    for (int i = sliceSz; i < (nvox-sliceSz-1); i++)
        img[i] = (sum[i-sliceSz] + sum[i] + sum[i] + sum[i+sliceSz]) / 64.0f; //below+2*center+above
    delete[] sum;
    SCALED_IMGDATA v;
    //we add the difference between the original (high+low freq) and blurred image (low freq) to amplify high freq
    if ( fslio->niftiptr->datatype == NIFTI_TYPE_UINT8) {
        THIS_UINT8 *inbuf = (THIS_UINT8 *) fslio->niftiptr->data;
        for (int i = 0; i < prefs->numVox3D; i++) {
            v = inbuf[i+volOffset] + inbuf[i+volOffset] - img[i];
            if (v < mn) v = mn;
            if (v > mx) v = mx;
            inbuf[i+volOffset] = v;
        }
    } else if ( fslio->niftiptr->datatype == NIFTI_TYPE_INT16) {
        THIS_INT16 *inbuf = (THIS_INT16 *) fslio->niftiptr->data;
        for (int i = 0; i < prefs->numVox3D; i++) {
            v = inbuf[i+volOffset] + inbuf[i+volOffset] - img[i];
            if (v < mn) v = mn;
            if (v > mx) v = mx;
            inbuf[i+volOffset] = v;
         }
    } else {
        SCALED_IMGDATA *inbuf = (SCALED_IMGDATA *) fslio->niftiptr->data;
        for (int i = 0; i < prefs->numVox3D; i++) {
            v = inbuf[i+volOffset] + inbuf[i+volOffset] - img[i];
            if (v < mn) v = mn;
            if (v > mx) v = mx;
            inbuf[i+volOffset] = v;
        }
    }
    delete[] img;
    prefs->force_refreshGL = true;
    prefs->force_recalcGL = true;
    return TRUE;
}

-(void) setBackgroundColor: (double) red Green: (double) green Blue: (double) blue; {
    prefs->backColor[0] = red;
    prefs->backColor[1] = green;
    prefs->backColor[2] = blue;
    prefs->force_recalcGL = true;
    prefs->force_refreshGL = true;
}

-(void)getBackgroundColor:(double*)red Green:(double*)green Blue:(double*)blue;
//Returns red, green, blue of background. To call:
//  double rgb[3];
//  [basic_opengl_view->Gniiimg getBackgroundColor:&rgb[0] Green:&rgb[1] Blue:&rgb[2] ];
{
    *red = prefs->backColor[0];
    *green = prefs->backColor[1];
    *blue = prefs->backColor[2];
}

-(void) setColorScheme: (int) clrIndex; {
    prefs->colorScheme = clrIndex;
    prefs->force_refreshGL = true;
    prefs->force_recalcGL = true;
}

-(void) setColorSchemeForLayer: (int) index Layer: (int) layer; {
    if ((layer > MAX_OVERLAY) || (layer <= 0)) { //2014x >= MAX_OVERLAY
        //adjust background
        [self setColorScheme: index];
        return;
    }
    //-1 as background is layer 0, so background 0 is layer 1
    prefs->overlays[layer-1].colorScheme = index;
    prefs->force_refreshGL = true;
    prefs->force_recalcGL = true;
}

-(void) setDisplayModeX: (int) mode; {
    #ifdef NII_IMG_RENDER //from nii_definetypes.h
    if ((mode == GL_2D_AND_3D) || (mode == GL_2D_ONLY) || (mode == GL_3D_ONLY)
         || (mode == GL_2D_AXIAL)  || (mode == GL_2D_CORONAL)  || (mode == GL_2D_SAGITTAL))
        prefs->displayModeGL = mode;
    scrnSize(prefs); //dimensions change with mode...
    prefs->force_refreshGL = true;
    //NSLog(@"mode %d %d",prefs->displayModeGL,mode);//2016
    #endif
}

-(void) setAzimElev: (int) azim Elev: (int) elev; {
    #ifdef NII_IMG_RENDER //from nii_definetypes.h
    if ((prefs->renderElevation == elev) && (prefs->renderAzimuth == azim)) return;
    prefs->renderElevation = elev;
    prefs->renderAzimuth = azim;
    if (prefs->renderElevation > 360) prefs->renderElevation = prefs->renderElevation-360;
    if (prefs->renderElevation < -360) prefs->renderElevation = prefs->renderElevation+360;
    //if (prefs->renderElevation > 90) prefs->renderElevation = 90;
    //if (prefs->renderElevation < -90) prefs->renderElevation = -90;
    prefs->force_refreshGL = true;
    #endif
}


-(void) setAzimElevInc: (int) azim Elev: (int) elev; {
    #ifdef NII_IMG_RENDER //from nii_definetypes.h
    if ( (0 == elev) && (0 == azim)) return;
    prefs->renderElevation = prefs->renderElevation+elev;
    prefs->renderAzimuth = prefs->renderAzimuth+azim;
    //if (prefs->renderElevation > 90) prefs->renderElevation = 90;
    //if (prefs->renderElevation < -90) prefs->renderElevation = -90;
    if (prefs->renderElevation > 360) prefs->renderElevation = prefs->renderElevation-360;
    if (prefs->renderElevation < -360) prefs->renderElevation = prefs->renderElevation+360;
    prefs->force_refreshGL = true;
    #endif
}

-(int) getVolume {
    return prefs->currentVolume;
}

-(int) getNumberOfVolumes {
    return prefs->numVolumes;
}

-(void) setVolume: (int) volume {
    if (volume > prefs->numVolumes)
        volume = 1; //loop or limit with prefs->numVolumes;
    if (volume < 1)
        volume = prefs->numVolumes;//loop, or limit with 1;
    prefs->currentVolume = volume;
    isInSection(0,0, false, prefs, fslio); //refresh mouse voxel intensity
    prefs->updatedTimeline = (prefs->numVolumes > 1); //adjust currentTimepoint
    prefs->force_refreshGL = true;
    prefs->force_recalcGL = true;
}

-(void) getAzimElev: (int *) azim Elev: (int *) elev; {
    *azim = prefs->renderAzimuth;
    *elev = prefs->renderElevation;
}

-(void) getClip: (int *) azim Elev: (int *) elev Depth: (int *) depth {
    *azim = prefs->clipAzimuth;
    *elev = prefs->clipElevation;
    *depth = prefs->clipDepth;
}

-(void) setClip: (int) azim Elev: (int) elev Depth: (int) depth {
    if (depth > MAX_CLIPDEPTH)
        depth = MAX_CLIPDEPTH;
    if (depth < 0)
        depth = 0;
    /*if (elev < -90)
        elev = -90;
    if (elev > 90)
        elev = 90;*/
    prefs->clipDepth = depth;
    prefs->clipAzimuth = azim;
    prefs->clipElevation = elev;
    if (prefs->clipElevation < -360)
        prefs->clipElevation = prefs->clipElevation + 360;
    if (prefs->clipElevation > 360)
        prefs->clipElevation = prefs->clipElevation - 360;
    prefs->force_refreshGL = true;
}

-(void) setScreenWidHt: (double) width Height: (double) height; {
    prefs->scrnHt = height ;
    prefs->scrnWid = width;
    scrnSize(prefs);
    prefs->force_refreshGL = true;
}

-(void) setScreenWidHtOffset: (double) width Height: (double) height OffsetX: (double) offsetX OffsetY: (double) offsetY; {
    prefs->scrnHt = height;
    prefs->scrnWid = width;
    prefs->scrnOffsetX = offsetX;
    prefs->scrnOffsetY = offsetY;
    prefs->scrnWid = width;
    scrnSize(prefs);
    prefs->force_refreshGL = true;
}

-(void) setViewMinMax: (double) min Max: (double) max; {
    prefs->viewMin = min;
    prefs->viewMax = max;
    prefs->force_refreshGL = true;
    prefs->force_recalcGL = true;
}

-(void) setViewMinMaxForLayer: (double) min Max: (double) max Layer: (int) layer  {
    if ((layer > MAX_OVERLAY) || (layer <= 0)) { //2014x >= MAX_OVERLAY
        //adjust background
        [self setViewMinMax: min Max: max];
        return;
    }
    //-1 as background is layer 0, so background 0 is layer 1
    prefs->overlays[layer-1].viewMin = min;
    prefs->overlays[layer-1].viewMax = max;
    prefs->force_refreshGL = true;
    prefs->force_recalcGL = true;
}

-(void) getViewMinMax: (double*) min Max: (double*) max; {
    *min = prefs->viewMin;
    *max = prefs->viewMax;
}

-(void) getSuggestedViewMinMax: (double*) min Max: (double*) max; {
    *min = prefs->nearMin;
    *max = prefs->nearMax;
}

int setLoadDummy(FSLIO* fslio, NII_PREFS* prefs)
{
    if (fslio==NULL)  {
        printf("loaddummy: Null pointer passed for FSLIO\n");
        return EXIT_FAILURE;
    }
    prefs->busyGL = TRUE;
    const int kSz = 48;
    struct nifti_1_header  nhdr = {.extents = 0}; //2014 array initializer
    nhdr.dim[0] = 3;
    nhdr.dim[1] = kSz;
    nhdr.dim[2] = kSz;
    nhdr.dim[3] = kSz;
    nhdr.pixdim[1] = 1;
    nhdr.pixdim[2] = 1;
    nhdr.pixdim[3] = 1;
    nhdr.magic[0]='n';
    nhdr.magic[1]='+';
    nhdr.magic[2]='1';
    nhdr.magic[3]='\0';
    nhdr.srow_x[0]=1; nhdr.srow_x[1]=0; nhdr.srow_x[2]=0; nhdr.srow_x[3]=-kSz/2;
    nhdr.srow_y[0]=0; nhdr.srow_y[1]=1; nhdr.srow_y[2]=0; nhdr.srow_y[3]=-kSz/2;
    nhdr.srow_z[0]=0; nhdr.srow_z[1]=0; nhdr.srow_z[2]=1; nhdr.srow_z[3]=-kSz/2;
    nhdr.sform_code = 1;
    nhdr.datatype = DT_UNSIGNED_CHAR;
    nhdr.bitpix = 8;
    nhdr.sizeof_hdr = 348;
    nhdr.vox_offset = 352;
    nhdr.scl_inter = 0;
    nhdr.scl_slope = 1;
    nifti_image *nim ;
    nim = nifti_convert_nhdr2nim(nhdr,"dummy.nii");
    fslio->niftiptr = nim;
    //nifti_image_infodump(fslio->niftiptr);
    THIS_UINT8 *outbuf = (THIS_UINT8 *) malloc(kSz*kSz*kSz);
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"nii_img dummy malloc size %d",kSz*kSz*kSz);
    #endif
    //fill array with simple image
    long i =0;
    for (i = 0; i < (kSz*kSz*kSz); i++) outbuf[i] = 0;
    int lo = 2; //border
    int hi = kSz-lo;
    i = 0;
    float *sins = (float *)malloc(sizeof(float) * kSz * kSz);
    float v = 0.5/kSz;
    for (int i = 0; i < (kSz*kSz); i++)
        sins[i] = sin(i * v);
    //create a 'Borg' using Paul Bourke's formula
    for (long z = 0; z < kSz; z++) {
        for (long y = 0; y < kSz; y++) {
            for (long x = 0; x < kSz; x++) {
                if ((x < lo) || (x > hi) || (y < lo) || (y > hi) || (z < lo) || (z > hi) )
                    outbuf[i] = 0; //outside border
                else if ((x>6) && (x<12) && (y > 6) && (y < 42))
                    outbuf[i] = 0;  //vertical of L
                else if ((x > 11) && (x < 24) && (y>6) && (y<12))
                    outbuf[i] = 0; //horizontal of L
                else {
                    v = sins[x * y] + sins[y * z] + sins[z * x];
                    if (v < 0) v = 0;
                    THIS_UINT8 b = round(255.0/3.0 * v);
                    outbuf[i] = b; //warning (kSz-1)*3 must be less than 255
                }
                i++;
            }
        }
    }
    /* //a simpler pattern
    for (long z = 0; z < kSz; z++) {
        for (long y = 0; y < kSz; y++) {
            for (long x = 0; x < kSz; x++) {
                if ((x < lo) || (x > hi) || (y < lo) || (y > hi) || (z < lo) || (z > hi) )
                    outbuf[i] = 0; //outside border
                else if ((x>6) && (x<12) && (y > 6) && (y < 42))
                    outbuf[i] = 0;  //vertical of L
                else if ((x > 11) && (x < 24) && (y>6) && (y<12))
                    outbuf[i] = 0; //horizontal of L
                else
                    outbuf[i] = x+y+z; //warning (kSz-1)*3 must be less than 255
                i++;
            }
        }
    }*/
    free(sins);
    free(fslio->niftiptr->data);
    fslio->niftiptr->data = outbuf;
    nii_setup(fslio, prefs);
    prefs->busyGL = FALSE;
    return EXIT_SUCCESS;
}

void closeOverlays (NII_PREFS* prefs)
{
    for (int i = 0; i < MAX_OVERLAY; i++) {
        if (prefs->overlays[i].datatype != DT_NONE) free(prefs->overlays[i].data); //free memory
        prefs->overlays[i].datatype = DT_NONE; //mark slot as free
    }
}

-(void) freePrefs
{
    FslClose(fslio);
    closeOverlays(prefs);
    freeCached8bit(prefs);
    [labelArray removeAllObjects];
    prefs->currentVolume = 1;
    fslio = FslInit();
}

-(int)  setLoadDTI: (NSString *) faname V1name: (NSString *) v1name //dummy loaded if filename blank or non-existent
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:v1name]) return EXIT_FAILURE;
    if (![[NSFileManager defaultManager] fileExistsAtPath:faname]) return EXIT_FAILURE;
    if (![self checkSandAccess2: v1name]) return EXIT_FAILURE;
    if (![self checkSandAccess2: faname]) return EXIT_FAILURE;
    prefs->busyGL = TRUE;
    [self freePrefs];
    //load FA
    char fname[ [faname length]+1];
    [faname getCString:fname maxLength:sizeof(fname)/sizeof(*fname) encoding:NSUTF8StringEncoding];
    int vol = FslReadVolumes(fslio,fname,0,1);
    if ((prefs->dicomWarn) && (fslio->niftiptr->isDICOM))
        [self notifyDICOMwarning];
    if (vol < 1) return setLoadDummy(fslio, prefs);
    //load 3 volumes vectors
    char vname[ [v1name length]+1];
    [v1name getCString:vname maxLength:sizeof(vname)/sizeof(*vname) encoding:NSUTF8StringEncoding];
    FSLIO* lfslio = FslInit();
    vol = FslReadVolumes(lfslio,vname,0,3);
    if ((prefs->dicomWarn) && (fslio->niftiptr->isDICOM))
        [self notifyDICOMwarning];
    if ((sizeof(SCALED_IMGDATA) == fslio->niftiptr->nbyper ) && (vol == 3) && (fslio->niftiptr->datatype == lfslio->niftiptr->datatype ) && (lfslio->niftiptr->dim[1] == fslio->niftiptr->dim[1]) && (lfslio->niftiptr->dim[2] == fslio->niftiptr->dim[2] ) && (lfslio->niftiptr->dim[3] == fslio->niftiptr->dim[3] ) ) {
        int nvox = fslio->niftiptr->dim[1]*fslio->niftiptr->dim[2]*fslio->niftiptr->dim[3];
        //THIS_UINT8 *rawRGB = (THIS_UINT8 *) fslio->niftiptr->data;
        THIS_UINT8 *outbuf = (THIS_UINT8 *) malloc(nvox * 4);
        SCALED_IMGDATA *faimg = (SCALED_IMGDATA *) fslio->niftiptr->data;
        SCALED_IMGDATA *v1img = (SCALED_IMGDATA *) lfslio->niftiptr->data;
        //inbuf[lXo+lYo+lZo];
        //int xyz = fslio->niftiptr->dim[1]*fslio->niftiptr->dim[2]*fslio->niftiptr->dim[3];
        int nvox2 = nvox * 2;
        int nvox3 = nvox * 3;
        for (int v = 0; v < (nvox3); v++)
            v1img[v] = fabs( v1img[v] );
        float mx = faimg[0];
        for (int v = 0; v < (nvox); v++)
            if (faimg[v]  > mx) mx = faimg[v];
//        if ((mx > 1.0) && (mx < 1.5)) {//FSL tends to have weird values >1 - clip to 1...
//            for (int v = 0; v < (nvox); v++)
//                if (faimg[v]  > 1.0) faimg[v] = 1.0;
//            mx = 1.0;
//        }
        int o = 0;

        float faval;
        for (int v = 0; v < nvox; v++) { //for each slice
            faval = faimg[v]/mx;
            if (faval < 0.0 ) faval = 0.0;
            faval = sqrt(faval) * 255.0;
            outbuf[o++] = round(v1img[v]*faval); //Red - 1st volume (Xdim=LR)
            outbuf[o++] =  round(v1img[v+nvox]*faval); //Green - 2nd volume (Ydim=PA)
            outbuf[o++] = round(v1img[v+nvox2]*faval); //Blue - 3rd volume (Zdim=IS)
            outbuf[o++] = round(faval); //green best estimate for alpha
        } //for each voxel
        free(fslio->niftiptr->data);
        fslio->niftiptr->data = outbuf;
        fslio->niftiptr->datatype =DT_RGBA32;
        fslio->niftiptr->nbyper = 4;
    }
    FslClose(lfslio);
    nii_setup(fslio, prefs);
    prefs->busyGL = FALSE;
    return EXIT_SUCCESS;
}

-(BOOL) checkSandAccess: (NSString *)file_name
{
    bool result = (!access([file_name UTF8String], R_OK) );
    if (result) return result; //already have access
#if TARGET_OS_OSX
    NSOpenPanel *openPanel  = [NSOpenPanel openPanel];
    [openPanel setDirectoryURL: [[NSURL alloc] initWithString:file_name]];
    //NSLog(@"selecting : %@",[FName lastPathComponent] ); // [FName lastPathComponent]
    openPanel.title = [@"Select file " stringByAppendingString:[file_name lastPathComponent]];
    NSString *Ext = [file_name pathExtension];
    NSArray *fileTypes = [NSArray arrayWithObjects: Ext, nil];
    [openPanel setAllowedFileTypes:fileTypes];
    [openPanel runModal];
    result = (!access([file_name UTF8String], R_OK) );
    if (result) return result; //already have access
    NSBeginAlertSheet(@"Unable to open image", @"OK",NULL,NULL, [[NSApplication sharedApplication] keyWindow], self,
                      NULL, NULL, NULL,
                      @"%@"
                      , [@"You do not have access to the file " stringByAppendingString:[file_name lastPathComponent]]);
#endif
    // iOS/iPadOS grants access via security-scoped URLs from UIDocumentPicker
    // (handled by the UIKit file-import layer in Phase 4), so there is no
    // AppKit open-panel fallback here.
    return result; //no access
}

-(BOOL) checkSandAccess2: (NSString *)file_name
{
    if (file_name.length < 3) return true;
    bool result = [self checkSandAccess: file_name];
    //bool result = checkSandAccess(file_name);
    if (!result) return result; //no access to primary file
    NSString *Ext = [file_name pathExtension];
    if ([Ext caseInsensitiveCompare:@"HDR"]== NSOrderedSame ) {
        Ext = @"img"; //hdr file requires img
    }   else if([Ext caseInsensitiveCompare:@"IMG"]== NSOrderedSame ) {
        Ext = @"hdr"; //img file requires hdr
    }  else  return result; //no secondary file
    NSString *FName = [NSString stringWithFormat:@"%@.%@", [file_name stringByDeletingPathExtension], Ext];
    return [self checkSandAccess: FName];
}

-(void) setLoadBVec: (NSString *) file_name rawvol:  (int) rawvols  {
    //NSLog(@"Loading bvecs : %@ %d",file_name, prefs->numVolumes);
    // prefs->loadFewVolumes xxxxxx

    if ((prefs->orthoOrient) || (rawvols < 2) || (prefs->numVolumes < 2)) return; //only if displaying 4D images in raw orientation
    NSString* theFileName = [file_name stringByDeletingPathExtension];
    if ([[theFileName pathExtension] rangeOfString:@"NII" options:NSCaseInsensitiveSearch].location != NSNotFound)
        theFileName = [theFileName stringByDeletingPathExtension]; //remove both .nii and .gz from img.nii.gz
    //NSLog(@"BVec! %@",theFileName);
    theFileName = [theFileName stringByAppendingString: @".bvec"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:theFileName]) return;
    if (![self checkSandAccess2: theFileName]) return;
    //NSLog(@"BVec!! %@",theFileName);
    FILE *header_file;
    header_file = fopen([theFileName cStringUsingEncoding:1], "r");
    if (header_file == NULL) {
        NSLog(@"Error opening %@ ", theFileName);
        return;
    }
    float val;
    for (int v = 0; v < 3; v++) {
        for (int i = 0; i < rawvols; i++) {
            int count = fscanf( header_file , "%f" , &val ) ;
            if ((count > 0) && (i < MAX_DTIvectors)) {
                //NSLog(@" %f<< %d",val, count);
                prefs->dtiV[i][v] = val;
                prefs->numDtiV = i+1;
            }
        } //for each i
    }//for v 0,1,2
    //NSLog(@" %gx%gx%g << %d",prefs->dtiV[0][0],prefs->dtiV[0][1],prefs->dtiV[0][2], prefs->numDtiV);
    //NSLog(@" %gx%gx%g << %d",prefs->dtiV[1][0],prefs->dtiV[1][1],prefs->dtiV[1][2], prefs->numDtiV);
    fclose( header_file ) ;
}

- (void)notifyImageTooBig
{
#if TARGET_OS_OSX
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.title = [NSString stringWithFormat:@"Image too large for volume rendering"];
    notification.informativeText = @"Display may be impaired";
    notification.soundName = NULL;
    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
    [NSTimer scheduledTimerWithTimeInterval: 4.5  target:self selector: @selector(closePopup) userInfo:self repeats:NO];
#endif
}

-(int)  setLoadImage2: (NSString *) file_name IsOverlay: (bool) isOverlay;
{
    if (![self checkSandAccess2: file_name]) return setLoadDummy(fslio, prefs);
    [self freePrefs];
    //fslio = FslInit();
    prefs->busyGL = TRUE;
    //strcpy( prefs->nii_prefs_fname, "" );//called in nii_setup
    //prefs->nii_prefs_fname ="";
    //if ([file_name isEqualToString:@""]) return setLoadDummy(fslio, prefs);
    if (([file_name length] < 1) || ([@"~" isEqualToString: file_name]) ) {
        setLoadDummy(fslio, prefs);
        return EXIT_FAILURE;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:file_name]) {
        NSLog(@"Unable to find file : %@",file_name);
        setLoadDummy(fslio, prefs);
        return EXIT_FAILURE;
    }
    char fname[ [file_name length]+1];
    [file_name getCString:fname maxLength:sizeof(fname)/sizeof(*fname) encoding:NSUTF8StringEncoding];
    int maxVols = INT_MAX;
    //if (prefs->loadFewVolumes) maxVols = 32;
    if (prefs->loadFewVolumes) maxVols = -1;
    if (isOverlay) maxVols = 1;
    void *buffer = FslReadAllVolumes(fslio,fname,maxVols);
    if (buffer == NULL) {
        fprintf(stderr, "Error opening and reading %s.\n",fname);
        [self notifyOpenFailed];
        setLoadDummy(fslio, prefs);
        return EXIT_FAILURE;
    }
    #define kMaxDim 1536
    if ((fslio->niftiptr->dim[1]> kMaxDim) || (fslio->niftiptr->dim[2]> kMaxDim) || (fslio->niftiptr->dim[3]> kMaxDim))
        [self notifyImageTooBig];
    if ((prefs->dicomWarn) && (fslio->niftiptr->isDICOM))
        [self notifyDICOMwarning];
    //if (fslio->niftiptr->rawvols > maxVols)
    //    [self notifyNotAllVolumesLoaded: maxVols RawVols: fslio->niftiptr->rawvols];
    if ((maxVols < 1) && (fslio->niftiptr->rawvols > fslio->niftiptr->dim[4]))
        [self notifyNotAllVolumesLoaded: fslio->niftiptr->dim[4] RawVols: fslio->niftiptr->rawvols];
    nii_setup(fslio, prefs);
    NSString* theFileName = [[file_name lastPathComponent] stringByDeletingPathExtension];
    if ([[theFileName pathExtension] rangeOfString:@"NII" options:NSCaseInsensitiveSearch].location != NSNotFound)
        theFileName = [theFileName stringByDeletingPathExtension]; //remove both .nii and .gz from .nii.gz
    //NSLog(@"%d", fslio->niftiptr->rawvols);
    [self setLoadBVec: file_name rawvol: fslio->niftiptr->rawvols];
    strcpy( prefs->nii_prefs_fname, [theFileName UTF8String] );
    //NSLog(@"%d -> %lld", (fslio->niftiptr->intent_code == NIFTI_INTENT_LABEL), fslio->niftiptr->iname_offset);
    if ((fslio->niftiptr->intent_code == NIFTI_INTENT_LABEL) && (fslio->niftiptr->iname_offset == 352))
    	readLabelsExt (file_name, labelArray);
    if ( (fslio->niftiptr->intent_code == NIFTI_INTENT_LABEL) && (fslio->niftiptr->iname_offset >400)
        && ( (fslio->niftiptr->iname_offset % 16) == 0))
        readLabels (file_name, 352, round(fslio->niftiptr->iname_offset-352), labelArray);
    //prefs->nii_prefs_fname = theFileName;//[[file_name lastPathComponent] stringByDeletingPathExtension];//666 file_name;
    prefs->busyGL = FALSE;
    return EXIT_SUCCESS;
}

-(int)  setLoadImage: (NSString *) file_name;
{
    return [self setLoadImage2: file_name IsOverlay: false];

/*
    if (![self checkSandAccess2: file_name]) return EXIT_FAILURE;
    [self freePrefs];
     //fslio = FslInit();
    prefs->busyGL = TRUE;
    //strcpy( prefs->nii_prefs_fname, "" );//called in nii_setup
    //prefs->nii_prefs_fname ="";
    //if ([file_name isEqualToString:@""]) return setLoadDummy(fslio, prefs);
    if (([file_name length] < 1) || ([@"~" isEqualToString: file_name]) )
        return setLoadDummy(fslio, prefs);
    if (![[NSFileManager defaultManager] fileExistsAtPath:file_name]) {
        NSLog(@"Unable to find file : %@",file_name);
        return setLoadDummy(fslio, prefs);
    }
    char fname[ [file_name length]+1];
    [file_name getCString:fname maxLength:sizeof(fname)/sizeof(*fname) encoding:NSUTF8StringEncoding];
    int maxVols = INT_MAX;
    if (prefs->loadFewVolumes) maxVols = 32;
    if (prefs->loadOverlay) maxVols = 1;
    void *buffer = FslReadAllVolumes(fslio,fname,maxVols, prefs->dicomWarn);
    if (buffer == NULL) {
        fprintf(stderr, "Error opening and reading %s.\n",fname);
        return setLoadDummy(fslio, prefs);
    }
    nii_setup(fslio, prefs);
    NSString* theFileName = [[file_name lastPathComponent] stringByDeletingPathExtension];
    if ([[theFileName pathExtension] rangeOfString:@"NII" options:NSCaseInsensitiveSearch].location != NSNotFound)
        theFileName = [theFileName stringByDeletingPathExtension]; //remove both .nii and .gz from .nii.gz

    [self setLoadBVec: file_name];
    strcpy( prefs->nii_prefs_fname, [theFileName UTF8String] );
    if ( (fslio->niftiptr->intent_code == NIFTI_INTENT_LABEL) && (fslio->niftiptr->iname_offset >400)
        && ( (fslio->niftiptr->iname_offset % 16) == 0))
        readLabels (file_name, 352, round(fslio->niftiptr->iname_offset-352), labelArray);
    //prefs->nii_prefs_fname = theFileName;//[[file_name lastPathComponent] stringByDeletingPathExtension];//666 file_name;
    prefs->busyGL = FALSE;
    return EXIT_SUCCESS;*/
}

-(FSLIO *) getFSLIO;
{
    return fslio;
}

// Streaming overlay: reslice `data` (a float volume in world/mm space) into an overlay
// slot and mark only the box it covers for re-composition. See the streaming-overlay
// notes above refreshOverlayRegionGL for why this exists.
- (int) updateStreamingOverlay: (int) slot
                     floatData: (const float *) data
                          dims: (const int *) dims
                     spacingMM: (const float *) spacingMM
                      originMM: (const float *) originMM
{
    if (slot < 0 || slot >= MAX_OVERLAY) return -1;
    if (data == NULL || dims == NULL || spacingMM == NULL || originMM == NULL) return -1;
    if (dims[0] < 1 || dims[1] < 1 || dims[2] < 1) return -1;
    if (prefs->numVox3D < 1) return -1;
    if (fslio->niftiptr->datatype == DT_NONE) return -1; //no background to overlay onto
    for (int d = 0; d < 3; d++) if (spacingMM[d] == 0) return -1;

    NII_OVERLAY *ov = &prefs->overlays[slot];
    const size_t nvox = prefs->numVox3D;
    if (ov->datatype != NIFTI_TYPE_FLOAT32 || ov->data == NULL) {
        // Taking over the slot: whatever was here (a loaded stat map) is replaced.
        if (ov->datatype != DT_NONE) free(ov->data);
        ov->data = calloc(nvox, sizeof(float));
        if (ov->data == NULL) { ov->datatype = DT_NONE; return -1; }
        ov->datatype = NIFTI_TYPE_FLOAT32;
        ov->scl_slope = 1.0f;
        ov->scl_inter = 0.0f;
        ov->lut_bias = 0.5f;
        ov->colorScheme = slot + 3;
        ov->fullMin = 0.0; ov->fullMax = 1.0;
        ov->nearMin = 0.0; ov->nearMax = 1.0;
        ov->viewMin = 0.0; ov->viewMax = 1.0;
    }
    float *dst = (float *) ov->data;

    // Destination box: the source's corners pushed through world -> background voxels.
    const int nx = prefs->voxelDim[1], ny = prefs->voxelDim[2], nz = prefs->voxelDim[3];
    mat44 toVox = prefs->sto_ijk;
    int lo[3] = {nx, ny, nz}, hi[3] = {-1, -1, -1};
    for (int c = 0; c < 8; c++) {
        float srcIdx[3] = { (c & 1) ? (float)(dims[0]-1) : 0.0f,
                            (c & 2) ? (float)(dims[1]-1) : 0.0f,
                            (c & 4) ? (float)(dims[2]-1) : 0.0f };
        float mm[3];
        for (int d = 0; d < 3; d++) mm[d] = originMM[d] + srcIdx[d] * spacingMM[d];
        for (int d = 0; d < 3; d++) {
            double v = toVox.m[d][0]*mm[0] + toVox.m[d][1]*mm[1] + toVox.m[d][2]*mm[2] + toVox.m[d][3];
            int iv = (int) floor(v);
            if (iv - 1 < lo[d]) lo[d] = iv - 1;
            if (iv + 1 > hi[d]) hi[d] = iv + 1;
        }
    }
    const int dim[3] = {nx, ny, nz};
    for (int d = 0; d < 3; d++) {
        if (lo[d] < 0) lo[d] = 0;
        if (hi[d] > dim[d] - 1) hi[d] = dim[d] - 1;
        if (lo[d] > hi[d]) return -1; //source lies outside the background
    }

    // Anything previously written outside the new box would linger, so re-compose the
    // union of the two and clear the part the new data does not cover.
    int unionLo[3], unionHi[3];
    bool hadBox = prefs->overlayDirtyHi[0] >= prefs->overlayDirtyLo[0];
    for (int d = 0; d < 3; d++) {
        unionLo[d] = hadBox ? MIN(lo[d], prefs->overlayDirtyLo[d]) : lo[d];
        unionHi[d] = hadBox ? MAX(hi[d], prefs->overlayDirtyHi[d]) : hi[d];
        if (unionLo[d] < 0) unionLo[d] = 0;
        if (unionHi[d] > dim[d] - 1) unionHi[d] = dim[d] - 1;
    }

    // One row of the box per work item: the reslice is the dominant cost of a streaming
    // update, and it is embarrassingly parallel (each destination voxel is written once).
    mat44 toMM = prefs->sto_xyz;
    const int rowsY = unionHi[1] - unionLo[1] + 1;
    const int rowsZ = unionHi[2] - unionLo[2] + 1;
    // Scalars, not the arrays: a block cannot capture a C array by value.
    const int uLo0 = unionLo[0], uLo1 = unionLo[1], uLo2 = unionLo[2];
    const int uHi0 = unionHi[0];
    const int sDim0 = dims[0], sDim1 = dims[1], sDim2 = dims[2];
    const float sOrg0 = originMM[0], sOrg1 = originMM[1], sOrg2 = originMM[2];
    const float sSpc0 = spacingMM[0], sSpc1 = spacingMM[1], sSpc2 = spacingMM[2];
    dispatch_apply(rowsZ * rowsY, DISPATCH_APPLY_AUTO, ^(size_t row_i) {
        const int z = uLo2 + (int)(row_i / rowsY);
        const int y = uLo1 + (int)(row_i % rowsY);
        {
            const size_t row = (size_t)z * nx * ny + (size_t)y * nx;
            for (int x = uLo0; x <= uHi0; x++) {
                const float mm0 = toMM.m[0][0]*x + toMM.m[0][1]*y + toMM.m[0][2]*z + toMM.m[0][3];
                const float mm1 = toMM.m[1][0]*x + toMM.m[1][1]*y + toMM.m[1][2]*z + toMM.m[1][3];
                const float mm2 = toMM.m[2][0]*x + toMM.m[2][1]*y + toMM.m[2][2]*z + toMM.m[2][3];
                // World -> source index (the source grid is axis-aligned by contract).
                const float f[3] = {(mm0 - sOrg0) / sSpc0, (mm1 - sOrg1) / sSpc1,
                                    (mm2 - sOrg2) / sSpc2};
                float value = 0.0f;
                if (f[0] >= 0 && f[1] >= 0 && f[2] >= 0 &&
                    f[0] <= sDim0-1 && f[1] <= sDim1-1 && f[2] <= sDim2-1) {
                    int i0 = (int)f[0], j0 = (int)f[1], k0 = (int)f[2];
                    int i1 = MIN(i0+1, sDim0-1), j1 = MIN(j0+1, sDim1-1), k1 = MIN(k0+1, sDim2-1);
                    float fx = f[0]-i0, fy = f[1]-j0, fz = f[2]-k0;
                    #define NII_SRC(ii,jj,kk) data[(size_t)(kk)*sDim0*sDim1 + (size_t)(jj)*sDim0 + (ii)]
                    float c00 = NII_SRC(i0,j0,k0)*(1-fx) + NII_SRC(i1,j0,k0)*fx;
                    float c10 = NII_SRC(i0,j1,k0)*(1-fx) + NII_SRC(i1,j1,k0)*fx;
                    float c01 = NII_SRC(i0,j0,k1)*(1-fx) + NII_SRC(i1,j0,k1)*fx;
                    float c11 = NII_SRC(i0,j1,k1)*(1-fx) + NII_SRC(i1,j1,k1)*fx;
                    #undef NII_SRC
                    float c0 = c00*(1-fy) + c10*fy, c1 = c01*(1-fy) + c11*fy;
                    value = c0*(1-fz) + c1*fz;
                }
                dst[row + x] = value;
            }
        }
    });

    for (int d = 0; d < 3; d++) {
        prefs->overlayDirtyLo[d] = unionLo[d];
        prefs->overlayDirtyHi[d] = unionHi[d];
    }
    prefs->force_overlayGL = true;
    prefs->force_refreshGL = true;
    return slot;
}

- (void) closeAllOverlays
{
    closeOverlays(prefs);
    prefs->overlayDirtyLo[0] = 0; prefs->overlayDirtyHi[0] = -1; //no streaming box
    prefs->force_overlayGL = false;
    prefs->force_refreshGL = true;
    prefs->force_recalcGL = true;
}

// Free ONE slot, so a layer that is reloaded often (a file-backed overlay) can be
// replaced without discarding a streaming layer in another slot.
- (void) closeOverlay: (int) slot
{
    if ((slot < 0) || (slot >= MAX_OVERLAY)) return;
    if (prefs->overlays[slot].datatype == DT_NONE) return;
    free(prefs->overlays[slot].data);
    prefs->overlays[slot].data = NULL;
    prefs->overlays[slot].datatype = DT_NONE;
    prefs->force_refreshGL = true;
    prefs->force_recalcGL = true;
}

- (int) nextOverlaySlot
{
    if (fslio->niftiptr->datatype == DT_NONE) return -1; //no background
    if (fslio->niftiptr->datatype == DT_RGBA32) return -1; //can't load overlays on RGB backgrounds
    for (int i = 0; i < MAX_OVERLAY; i++)
        if (prefs->overlays[i].datatype == DT_NONE) return i; //empty slot
    return -1; //all slots full
}

-(void) setPrefsOrient: (bool) loadOrtho;
{
    prefs->orthoOrient = loadOrtho;
}

- (int) addOverlay: (NSString *) file_name
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:file_name]) return -1;
    int overlayNum = [self nextOverlaySlot];
    if (overlayNum < 0) return overlayNum;
    nii_img *lniiimg;
    lniiimg = [nii_img alloc];
    lniiimg = [lniiimg init];
    NSString *lname =  file_name;
    [lniiimg setPrefsOrient:prefs->orthoOrient];
    [lniiimg setLoadImage2:lname IsOverlay: true];
    FSLIO *over = [lniiimg getFSLIO];
    NII_PREFS *overp = [lniiimg getPREFS];
    //if (reslice2Targ (fslio, over, FALSE) == EXIT_FAILURE) {
    if (reslice2Targ (fslio, over, TRUE) == EXIT_FAILURE) {
    #if !__has_feature(objc_arc)
        [lniiimg release];
        #endif
        return -1;
    }
    //copy data to overlay
    prefs->overlays[overlayNum].lut_bias = 0.5;
    prefs->overlays[overlayNum].scl_inter = over->niftiptr->scl_inter;
    prefs->overlays[overlayNum].scl_slope = over->niftiptr->scl_slope;
    prefs->overlays[overlayNum].datatype = over->niftiptr->datatype;
    prefs->overlays[overlayNum].fullMin = overp->fullMin;
    prefs->overlays[overlayNum].fullMax = overp->fullMax;
    if ((overp->viewMin < 0) && (overp->viewMax > 0))
        overp->viewMin = overp->viewMax;
    prefs->overlays[overlayNum].viewMin = overp->viewMin;
    prefs->overlays[overlayNum].viewMax = overp->viewMax;
    prefs->overlays[overlayNum].nearMin = overp->nearMin;
    prefs->overlays[overlayNum].nearMax = overp->nearMax;
    prefs->overlays[overlayNum].colorScheme = overlayNum + 3;
    //printf(" OVERLAY %d %f %f\n", overlayNum, prefs->overlays[overlayNum].viewMin, prefs->overlays[overlayNum].viewMax );
    THIS_UINT8 *outbuf = (THIS_UINT8 *) malloc(prefs->numVox3D*over->niftiptr->nbyper);
    memcpy (outbuf, over->niftiptr->data, prefs->numVox3D*over->niftiptr->nbyper);
    prefs->overlays[overlayNum].data = outbuf;
     #if !__has_feature(objc_arc)
    [lniiimg release];
    #endif
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"Loaded overlay %d", overlayNum);
    #endif
    prefs->force_refreshGL = true;
    prefs->force_recalcGL = true;
    return overlayNum; //all slots full
}

-(NII_PREFS *) getPREFS;
{
    return prefs;
}

-(NSString *) getHeaderInfo;
{
    if (!fslio || !fslio->niftiptr) return @"";
    nifti_image *n = fslio->niftiptr;
    // NIfTI datatype code -> readable name
    const char *dt;
    switch (n->datatype) {
        case 2:   dt = "uint8";   break;
        case 4:   dt = "int16";   break;
        case 8:   dt = "int32";   break;
        case 16:  dt = "float32"; break;
        case 64:  dt = "float64"; break;
        case 256: dt = "int8";    break;
        case 512: dt = "uint16";  break;
        case 768: dt = "uint32";  break;
        default:  dt = "?";       break;
    }
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"Dimensions: %d × %d × %d", n->nx, n->ny, n->nz];
    if (prefs->numVolumes > 1) [s appendFormat:@" × %d volumes", prefs->numVolumes];
    [s appendFormat:@"\nVoxel size: %g × %g × %g mm", defuzzz(n->dx), defuzzz(n->dy), defuzzz(n->dz)];
    if (prefs->numVolumes > 1 && n->pixdim[4] > 0) [s appendFormat:@"\nTR: %g s", defuzzz(n->pixdim[4])];
    [s appendFormat:@"\nData type: %s (%d bytes/voxel)", dt, n->nbyper];
    double mn = 0, mx = 0; [self getViewMinMax:&mn Max:&mx];
    [s appendFormat:@"\nDisplay range: %g … %g", defuzzz(mn), defuzzz(mx)];
    BOOL spatial = (n->sform_code != NIFTI_XFORM_UNKNOWN) || (n->qform_code != NIFTI_XFORM_UNKNOWN);
    [s appendFormat:@"\nSpatial transform: %@", spatial ? @"yes (oriented)" : @"none"];
    if (n->isDICOM) [s appendString:@"\nSource: DICOM"];
    if (n->descrip[0] != '\0')
        [s appendFormat:@"\nDescription: %s", n->descrip];
    return s;
}

- (id)init
{
    self = [super init];
    if (self) {
        // Initialization code here.
        fslio = FslInit();
        //fslio->niftiptr->datatype = DT_NONE;
        prefs = (NII_PREFS *) calloc(1,sizeof(NII_PREFS));
        prefs->currentVolume = 1;
        prefs->lut_bias = 0.5;
        prefs->numVolumes = 1;
        prefs->mouseX = -1; //no previous click...
        //prefs->xBarColor[0] = 1.0;
        prefs->backColor[0] = 0.0;
        prefs->backColor[1] = 0.0;
        prefs->backColor[2] = 0.0;
        prefs->xBarColor[0] = 0.3;
        prefs->xBarColor[1] = 0.3;
        prefs->xBarColor[2] = 1.0;
        prefs->colorBarBorderColor[0] = 0.25;
        prefs->colorBarBorderColor[1] = 0.25;
        prefs->colorBarBorderColor[2] = 0.75;
        prefs->colorBarTextColor[0] = 0.5;
        prefs->colorBarTextColor[1] = 0.5;
        prefs->colorBarTextColor[2] = 0.5;
        prefs->colorBarPos[0] = 0.94; //left
        prefs->colorBarPos[1] = 0.125;//bottom
        prefs->colorBarPos[2] = 0.98;  //right
        prefs->colorBarPos[3] = 0.98;  //top
        prefs->xBarGap = 3;
        prefs->overlayFrac = 0.5;
        prefs->colorBarBorderPx = 2; // 1/2%

        //x prefs->colorBarBorder = 0.002; // 1/2%
        prefs->cached8bit = NULL;
        prefs->cached8bitVox = 0;
        prefs->force_overlayGL = false;
        prefs->overlayDirtyLo[0] = 0; //empty box: hi < lo, so the first streaming update
        prefs->overlayDirtyHi[0] = -1; //  does not union with the volume's origin
        prefs->busyGL = FALSE; //prepared for drawing
        prefs->updatedTimeline = FALSE;
        prefs->numDtiV = 0;
        prefs->orthoOrient = true;
        prefs->advancedRender = false;
        prefs->loadFewVolumes = true;
        prefs->viewRadiological = false;
        prefs->isSmooth2D = false;

        for (int i = 0; i < MAX_OVERLAY; i++) prefs->overlays[i].datatype = DT_NONE; //all slots empty
        #ifdef NII_IMG_RENDER
        initTRayCast(prefs);
        #endif
        labelArray = [[NSMutableArray alloc]init];
        // (text is now rasterized by NIIMetalText; the GLString glyph cache + its
        //  NSFont/NSColor attribute dictionary are gone)
    }
    return self;
}

- (void) updateFont: (PlatformColor *) aColor {
    // Metal text (NIIMetalText) picks its tint from the background at draw time
    // in drawMetalOverlays, so there's nothing to cache here now.
    (void)aColor;
}

- (void) updateFontScale: (float) scale {
    // GLString scale is obsolete — NIIMetalText sizes glyphs per Retina backing.
    (void)scale;
}



- (void)dealloc
{
    [self closeAllOverlays];
    // GPU resources (3D textures, shader programs) are now owned and released by
    // the per-window NIIMetalRenderer (_metalRenderer); no GL handles to free here.
    [self freePrefs];
    FslClose(fslio);
    #if !__has_feature(objc_arc)
    [super dealloc];
    #endif
}

@end
