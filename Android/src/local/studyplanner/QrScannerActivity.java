package local.studyplanner;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.ImageFormat;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.*;
import android.media.Image;
import android.media.ImageReader;
import android.os.*;
import android.util.Size;
import android.view.*;
import android.widget.*;
import com.google.zxing.*;
import com.google.zxing.common.HybridBinarizer;
import java.nio.ByteBuffer;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** Minimal in-app QR scanner. Frames stay in memory and are never saved. */
public final class QrScannerActivity extends Activity {
    static final String EXTRA_RESULT="qr";
    private static final int CAMERA_PERMISSION=41;
    private TextureView preview;
    private CameraDevice camera;
    private CameraCaptureSession session;
    private ImageReader images;
    private HandlerThread cameraThread;
    private Handler cameraHandler;
    private final AtomicBoolean decoding=new AtomicBoolean(false);
    private final MultiFormatReader reader=new MultiFormatReader();

    @Override public void onCreate(Bundle state){
        super.onCreate(state);
        reader.setHints(new EnumMap<DecodeHintType,Object>(DecodeHintType.class){{
            put(DecodeHintType.POSSIBLE_FORMATS,Collections.singletonList(BarcodeFormat.QR_CODE));
            put(DecodeHintType.TRY_HARDER,Boolean.TRUE);
            put(DecodeHintType.CHARACTER_SET,"UTF-8");
        }});
        FrameLayout root=new FrameLayout(this);root.setBackgroundColor(Color.BLACK);
        preview=new TextureView(this);root.addView(preview,new FrameLayout.LayoutParams(-1,-1));
        LinearLayout overlay=new LinearLayout(this);overlay.setOrientation(LinearLayout.VERTICAL);overlay.setGravity(Gravity.CENTER_HORIZONTAL);overlay.setPadding(dp(22),dp(18),dp(22),dp(28));overlay.setBackgroundColor(0x88000000);
        TextView title=new TextView(this);title.setText("扫描 Mac 上的配对二维码");title.setTextColor(Color.WHITE);title.setTextSize(19);title.setGravity(Gravity.CENTER);overlay.addView(title,new LinearLayout.LayoutParams(-1,-2));
        TextView detail=new TextView(this);detail.setText("二维码只用于本次配对，摄像头画面不会保存。");detail.setTextColor(0xffd7dce5);detail.setTextSize(13);detail.setGravity(Gravity.CENTER);detail.setPadding(0,dp(7),0,0);overlay.addView(detail,new LinearLayout.LayoutParams(-1,-2));
        Button cancel=new Button(this);cancel.setText("取消");cancel.setOnClickListener(v->finish());overlay.addView(cancel,new LinearLayout.LayoutParams(-2,-2));
        FrameLayout.LayoutParams op=new FrameLayout.LayoutParams(-1,-2,Gravity.BOTTOM);root.addView(overlay,op);setContentView(root);
        preview.setSurfaceTextureListener(new TextureView.SurfaceTextureListener(){
            public void onSurfaceTextureAvailable(SurfaceTexture texture,int width,int height){openCamera();}
            public void onSurfaceTextureSizeChanged(SurfaceTexture texture,int width,int height){}
            public boolean onSurfaceTextureDestroyed(SurfaceTexture texture){return true;}
            public void onSurfaceTextureUpdated(SurfaceTexture texture){}
        });
    }

    @Override protected void onResume(){super.onResume();cameraThread=new HandlerThread("planner-qr-camera");cameraThread.start();cameraHandler=new Handler(cameraThread.getLooper());if(preview.isAvailable())openCamera();}
    @Override protected void onPause(){closeCamera();if(cameraThread!=null){cameraThread.quitSafely();try{cameraThread.join(1000);}catch(InterruptedException e){Thread.currentThread().interrupt();}cameraThread=null;cameraHandler=null;}super.onPause();}

    private void openCamera(){
        if(camera!=null||cameraHandler==null)return;
        if(checkSelfPermission(Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED){requestPermissions(new String[]{Manifest.permission.CAMERA},CAMERA_PERMISSION);return;}
        try{
            CameraManager manager=getSystemService(CameraManager.class);String chosen=null;Size size=null;
            for(String id:manager.getCameraIdList()){
                CameraCharacteristics info=manager.getCameraCharacteristics(id);
                Integer facing=info.get(CameraCharacteristics.LENS_FACING);if(facing!=null&&facing==CameraCharacteristics.LENS_FACING_BACK){chosen=id;Size[] supported=info.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP).getOutputSizes(ImageFormat.YUV_420_888);size=choose(supported);break;}
            }
            if(chosen==null){Toast.makeText(this,"未找到后置摄像头",Toast.LENGTH_LONG).show();finish();return;}
            images=ImageReader.newInstance(size.getWidth(),size.getHeight(),ImageFormat.YUV_420_888,2);images.setOnImageAvailableListener(this::decode,cameraHandler);
            manager.openCamera(chosen,new CameraDevice.StateCallback(){
                public void onOpened(CameraDevice value){camera=value;startPreview();}
                public void onDisconnected(CameraDevice value){value.close();camera=null;}
                public void onError(CameraDevice value,int error){value.close();camera=null;runOnUiThread(()->{Toast.makeText(QrScannerActivity.this,"无法打开摄像头",Toast.LENGTH_LONG).show();finish();});}
            },cameraHandler);
        }catch(Exception e){Toast.makeText(this,"摄像头启动失败："+e.getClass().getSimpleName(),Toast.LENGTH_LONG).show();finish();}
    }

    private Size choose(Size[] sizes){
        Size best=sizes[0];long target=1280L*720;
        for(Size value:sizes){long area=(long)value.getWidth()*value.getHeight();if(area>=640L*480&&Math.abs(area-target)<Math.abs((long)best.getWidth()*best.getHeight()-target))best=value;}
        return best;
    }

    private void startPreview(){
        try{
            SurfaceTexture texture=preview.getSurfaceTexture();Size size=new Size(images.getWidth(),images.getHeight());texture.setDefaultBufferSize(size.getWidth(),size.getHeight());Surface screen=new Surface(texture),frames=images.getSurface();
            CaptureRequest.Builder request=camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);request.addTarget(screen);request.addTarget(frames);request.set(CaptureRequest.CONTROL_AF_MODE,CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE);request.set(CaptureRequest.CONTROL_AE_MODE,CaptureRequest.CONTROL_AE_MODE_ON);
            camera.createCaptureSession(Arrays.asList(screen,frames),new CameraCaptureSession.StateCallback(){
                public void onConfigured(CameraCaptureSession value){session=value;try{value.setRepeatingRequest(request.build(),null,cameraHandler);}catch(CameraAccessException e){finish();}}
                public void onConfigureFailed(CameraCaptureSession value){runOnUiThread(()->{Toast.makeText(QrScannerActivity.this,"取景启动失败",Toast.LENGTH_LONG).show();finish();});}
            },cameraHandler);
        }catch(Exception e){finish();}
    }

    private void decode(ImageReader source){
        Image image=source.acquireLatestImage();if(image==null)return;
        if(!decoding.compareAndSet(false,true)){image.close();return;}
        try{
            int width=image.getWidth(),height=image.getHeight();Image.Plane plane=image.getPlanes()[0];ByteBuffer buffer=plane.getBuffer();int rowStride=plane.getRowStride(),pixelStride=plane.getPixelStride();byte[] luminance=new byte[width*height];
            if(pixelStride==1&&rowStride==width)buffer.get(luminance);
            else{byte[] row=new byte[rowStride];for(int y=0;y<height;y++){int length=Math.min(rowStride,buffer.remaining());buffer.get(row,0,length);for(int x=0;x<width;x++)luminance[y*width+x]=row[Math.min(x*pixelStride,length-1)];}}
            LuminanceSource yuv=new PlanarYUVLuminanceSource(luminance,width,height,0,0,width,height,false);Result result=reader.decodeWithState(new BinaryBitmap(new HybridBinarizer(yuv)));
            if(result!=null&&!result.getText().isEmpty()){Intent reply=new Intent().putExtra(EXTRA_RESULT,result.getText());runOnUiThread(()->{setResult(RESULT_OK,reply);finish();});}
        }catch(ReaderException ignored){}finally{reader.reset();image.close();decoding.set(false);}
    }

    private void closeCamera(){if(session!=null){session.close();session=null;}if(camera!=null){camera.close();camera=null;}if(images!=null){images.close();images=null;}}
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] results){super.onRequestPermissionsResult(request,permissions,results);if(request==CAMERA_PERMISSION&&results.length>0&&results[0]==PackageManager.PERMISSION_GRANTED)openCamera();else{Toast.makeText(this,"扫码需要摄像头权限",Toast.LENGTH_LONG).show();finish();}}
    private int dp(int value){return (int)(value*getResources().getDisplayMetrics().density+.5f);}
}
