//
// ViewController.m
//
// Created by rock88
// Modified by xSacha
//

#import "AppDelegate.h"
#import "ViewController.h"
#import "DisplayManager.h"
#include "Controls.h"
#import "iOSCoreAudio.h"

#import <GLKit/GLKit.h>
#include <cassert>

#include "Common/Net/Resolve.h"
#include "Common/UI/Screen.h"
#include "Common/GPU/thin3d.h"
#include "Common/GPU/thin3d_create.h"
#include "Common/GPU/OpenGL/GLRenderManager.h"
#include "Common/GPU/OpenGL/GLFeatures.h"
#include "Common/Data/Encoding/Utf8.h"
#include "Common/System/Display.h"
#include "Common/System/System.h"
#include "Common/System/OSD.h"
#include "Common/System/NativeApp.h"
#include "Common/File/VFS/VFS.h"
#include "Common/Thread/ThreadUtil.h"
#include "Common/Log.h"
#include "Common/TimeUtil.h"
#include "Common/Input/InputState.h"
#include "Common/Input/KeyCodes.h"
#include "Common/GraphicsContext.h"

#include "Core/Config.h"
#include "Core/ConfigValues.h"
#include "Core/KeyMap.h"
#include "Core/System.h"
#include "Core/HLE/sceUsbCam.h"
#include "Core/HLE/sceUsbGps.h"

#if !__has_feature(objc_arc)
#error Must be built with ARC, please revise the flags for ViewController.mm to include -fobjc-arc.
#endif

class IOSGLESContext : public GraphicsContext {
public:
	IOSGLESContext() {
		CheckGLExtensions();
		draw_ = Draw::T3DCreateGLContext(false);
		renderManager_ = (GLRenderManager *)draw_->GetNativeObject(Draw::NativeObject::RENDER_MANAGER);
		renderManager_->SetInflightFrames(g_Config.iInflightFrames);
		SetGPUBackend(GPUBackend::OPENGL);
		bool success = draw_->CreatePresets();
		_assert_msg_(success, "Failed to compile preset shaders");
	}
	~IOSGLESContext() {
		delete draw_;
	}
	Draw::DrawContext *GetDrawContext() override {
		return draw_;
	}

	void Resize() override {}
	void Shutdown() override {}

	void ThreadStart() override {
		renderManager_->ThreadStart(draw_);
	}

	bool ThreadFrame() override {
		return renderManager_->ThreadFrame();
	}

	void ThreadEnd() override {
		renderManager_->ThreadEnd();
	}

	void StartThread() {
		renderManager_->StartThread();
	}

	void StopThread() override {
		renderManager_->StopThread();
	}

private:
	Draw::DrawContext *draw_;
	GLRenderManager *renderManager_;
};

static std::atomic<bool> exitRenderLoop;
static std::atomic<bool> renderLoopRunning;
static std::thread g_renderLoopThread;

id<PPSSPPViewController> sharedViewController;

@interface PPSSPPViewControllerGL () {
	ICadeTracker g_iCadeTracker;
	TouchTracker g_touchTracker;

	IOSGLESContext *graphicsContext;
	LocationHelper *locationHelper;
	CameraHelper *cameraHelper;
}

@property (nonatomic, strong) EAGLContext* context;

//@property (nonatomic) iCadeReaderView* iCadeView;
@property (nonatomic) GCController *gameController __attribute__((weak_import));
@property (strong, nonatomic) CMMotionManager *motionManager;
@property (strong, nonatomic) NSOperationQueue *accelerometerQueue;

@end

@implementation PPSSPPViewControllerGL

-(id) init {
	self = [super init];
	if (self) {
		sharedViewController = self;
		g_iCadeTracker.InitKeyMap();

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillTerminate:) name:UIApplicationWillTerminateNotification object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(controllerDidConnect:) name:GCControllerDidConnectNotification object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(controllerDidDisconnect:) name:GCControllerDidDisconnectNotification object:nil];
	}
	self.accelerometerQueue = [[NSOperationQueue alloc] init];
	self.accelerometerQueue.name = @"AccelerometerQueue";
	self.accelerometerQueue.maxConcurrentOperationCount = 1;
	return self;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (void)shareText:(NSString *)text {
	NSArray *items = @[text];
	UIActivityViewController * viewController = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
	dispatch_async(dispatch_get_main_queue(), ^{
		[self presentViewController:viewController animated:YES completion:nil];
	});
}

extern float g_safeInsetLeft;
extern float g_safeInsetRight;
extern float g_safeInsetTop;
extern float g_safeInsetBottom;

- (void)viewSafeAreaInsetsDidChange {
	if (@available(iOS 11.0, *)) {
		[super viewSafeAreaInsetsDidChange];
		// we use 0.0f instead of safeAreaInsets.bottom because the bottom overlay isn't disturbing (for now)
		g_safeInsetLeft = self.view.safeAreaInsets.left;
		g_safeInsetRight = self.view.safeAreaInsets.right;
		g_safeInsetTop = self.view.safeAreaInsets.top;
		g_safeInsetBottom = 0.0f;
	}
}

// The actual rendering is NOT on this thread, this is the emu thread
// that runs game logic.
void GLRenderLoop(IOSGLESContext *graphicsContext) {
	SetCurrentThreadName("EmuThreadGL");
	renderLoopRunning = true;

	NativeInitGraphics(graphicsContext);

	INFO_LOG(SYSTEM, "Emulation thread starting\n");
	while (!exitRenderLoop) {
		NativeFrame(graphicsContext);
	}

	INFO_LOG(SYSTEM, "Emulation thread shutting down\n");
	NativeShutdownGraphics();

	// Also ask the main thread to stop, so it doesn't hang waiting for a new frame.
	INFO_LOG(SYSTEM, "Emulation thread stopping\n");

	exitRenderLoop = false;
	renderLoopRunning = false;
}

- (bool)runGLRenderLoop {
	if (!graphicsContext) {
		ERROR_LOG(G3D, "runVulkanRenderLoop: Tried to enter without a created graphics context.");
		return false;
	}

	if (g_renderLoopThread.joinable()) {
		ERROR_LOG(G3D, "runVulkanRenderLoop: Already running");
		return false;
	}

	_dbg_assert_(!renderLoopRunning);
	_dbg_assert_(!exitRenderLoop);

	graphicsContext->StartThread();

	g_renderLoopThread = std::thread(GLRenderLoop, graphicsContext);
	return true;
}

- (void)requestExitGLRenderLoop {
	if (!renderLoopRunning) {
		ERROR_LOG(SYSTEM, "Render loop already exited");
		return;
	}
	_assert_(g_renderLoopThread.joinable());
	exitRenderLoop = true;
	graphicsContext->StopThread();
	while (graphicsContext->ThreadFrame()) {
		continue;
	}
	g_renderLoopThread.join();
	_assert_(!g_renderLoopThread.joinable());
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	[self hideKeyboard];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	[[DisplayManager shared] setupDisplayListener];

	UIScreen* screen = [(AppDelegate*)[UIApplication sharedApplication].delegate screen];
	self.view.frame = [screen bounds];
	self.view.multipleTouchEnabled = YES;
	self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];

	if (!self.context) {
		self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
	}

	GLKView* view = (GLKView *)self.view;
	view.context = self.context;
	view.drawableDepthFormat = GLKViewDrawableDepthFormat24;
	view.drawableStencilFormat = GLKViewDrawableStencilFormat8;
	[EAGLContext setCurrentContext:self.context];
	self.preferredFramesPerSecond = 60;  // NOTE: We don't yet take advantage of 120hz screens

	[[DisplayManager shared] updateResolution:[UIScreen mainScreen]];

	graphicsContext = new IOSGLESContext();

	graphicsContext->GetDrawContext()->SetErrorCallback([](const char *shortDesc, const char *details, void *userdata) {
		g_OSD.Show(OSDType::MESSAGE_ERROR, details, 0.0f, "error_callback");
	}, nullptr);

	graphicsContext->ThreadStart();

	/*self.iCadeView = [[iCadeReaderView alloc] init];
	[self.view addSubview:self.iCadeView];
	self.iCadeView.delegate = self;
	self.iCadeView.active = YES;*/

	if ([[GCController controllers] count] > 0) {
		[self setupController:[[GCController controllers] firstObject]];
	}

	cameraHelper = [[CameraHelper alloc] init];
	[cameraHelper setDelegate:self];

	locationHelper = [[LocationHelper alloc] init];
	[locationHelper setDelegate:self];

	[self hideKeyboard];

	UIScreenEdgePanGestureRecognizer *mBackGestureRecognizer = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipeFrom:) ];
	[mBackGestureRecognizer setEdges:UIRectEdgeLeft];
	[[self view] addGestureRecognizer:mBackGestureRecognizer];

	// Initialize the motion manager for accelerometer control.
	self.motionManager = [[CMMotionManager alloc] init];
	INFO_LOG(G3D, "Done with viewDidLoad.");
}

- (void)handleSwipeFrom:(UIScreenEdgePanGestureRecognizer *)recognizer
{
	if (recognizer.state == UIGestureRecognizerStateEnded) {
		KeyInput key;
		key.flags = KEY_DOWN | KEY_UP;
		key.keyCode = NKCODE_BACK;
		key.deviceId = DEVICE_ID_TOUCH;
		NativeKey(key);
		INFO_LOG(SYSTEM, "Detected back swipe");
	}
}

- (void)appWillTerminate:(NSNotification *)notification
{
	[self shutdown];
}

- (void)didBecomeActive {
	INFO_LOG(SYSTEM, "didBecomeActive begin");
	if (self.motionManager.accelerometerAvailable) {
		self.motionManager.accelerometerUpdateInterval = 1.0 / 60.0;
		INFO_LOG(G3D, "Starting accelerometer updates.");

		[self.motionManager startAccelerometerUpdatesToQueue:self.accelerometerQueue
							withHandler:^(CMAccelerometerData *accelerometerData, NSError *error) {
			if (error) {
				NSLog(@"Accelerometer error: %@", error);
				return;
			}
			ProcessAccelerometerData(accelerometerData);
		}];
	} else {
		INFO_LOG(G3D, "No accelerometer available, not starting updates.");
	}
	[self runGLRenderLoop];
	INFO_LOG(SYSTEM, "didBecomeActive end");
}

- (void)willResignActive {
	INFO_LOG(SYSTEM, "willResignActive begin");
	[self requestExitGLRenderLoop];

	// Stop accelerometer updates
	if (self.motionManager.accelerometerActive) {
		INFO_LOG(G3D, "Stopping accelerometer updates");
		[self.motionManager stopAccelerometerUpdates];
	}
	INFO_LOG(SYSTEM, "willResignActive end");
}

- (void)shutdown
{
	INFO_LOG(SYSTEM, "shutdown GL");

	g_Config.Save("shutdown GL");

	_dbg_assert_(graphicsContext);
	_dbg_assert_(sharedViewController != nil);
	sharedViewController = nil;

	if (self.context) {
		if ([EAGLContext currentContext] == self.context) {
			[EAGLContext setCurrentContext:nil];
		}
		self.context = nil;
	}

	[[NSNotificationCenter defaultCenter] removeObserver:self];

	self.gameController = nil;

	graphicsContext->StopThread();
	// Skipping GL calls here because the old context is lost.
	while (graphicsContext->ThreadFrame()) {
		continue;
	}
	graphicsContext->Shutdown();
	delete graphicsContext;
	graphicsContext = nullptr;
	INFO_LOG(SYSTEM, "Done shutting down GL");
}

- (void)dealloc
{
	INFO_LOG(SYSTEM, "dealloc GL");
}

- (NSUInteger)supportedInterfaceOrientations
{
	return UIInterfaceOrientationMaskLandscape;
}

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect
{
	if (!renderLoopRunning) {
		INFO_LOG(G3D, "Ignoring drawInRect");
		return;
	}
	if (sharedViewController) {
		graphicsContext->ThreadFrame();
	}
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	g_touchTracker.Began(touches, self.view);
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
	g_touchTracker.Moved(touches, self.view);
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
	g_touchTracker.Ended(touches, self.view);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	g_touchTracker.Cancelled(touches, self.view);
}

- (void)bindDefaultFBO
{
	[(GLKView*)self.view bindDrawable];
}

- (void)buttonDown:(iCadeState)button
{
	g_iCadeTracker.ButtonDown(button);
}

- (void)buttonUp:(iCadeState)button
{
	g_iCadeTracker.ButtonUp(button);
}

- (void)controllerDidConnect:(NSNotification *)note
{
	if (![[GCController controllers] containsObject:self.gameController]) self.gameController = nil;

	if (self.gameController != nil) return; // already have a connected controller

	[self setupController:(GCController *)note.object];
}

- (void)controllerDidDisconnect:(NSNotification *)note
{
	if (self.gameController == note.object) {
		self.gameController = nil;

		if ([[GCController controllers] count] > 0) {
			[self setupController:[[GCController controllers] firstObject]];
		}
	}
}

// Enables tapping for edge area.
-(UIRectEdge)preferredScreenEdgesDeferringSystemGestures
{
	if (GetUIState() == UISTATE_INGAME) {
		// In-game, we need all the control we can get. Though, we could possibly
		// allow the top edge?
		INFO_LOG(SYSTEM, "Defer system gestures on all edges");
		return UIRectEdgeAll;
	} else {
		INFO_LOG(SYSTEM, "Allow system gestures on the bottom");
		// Allow task switching gestures to take precedence, without causing
		// scroll events in the UI.
		return UIRectEdgeTop | UIRectEdgeLeft | UIRectEdgeRight;
	}
}

- (void)uiStateChanged
{
	[self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
	[self hideKeyboard];
}

- (UIView *)getView {
	return [self view];
}

- (void)setupController:(GCController *)controller
{
	self.gameController = controller;
	if (!SetupController(controller)) {
		self.gameController = nil;
	}
}

- (void)startVideo:(int)width height:(int)height {
	[cameraHelper startVideo:width h:height];
}

- (void)stopVideo {
	[cameraHelper stopVideo];
}

- (void)PushCameraImageIOS:(long long)len buffer:(unsigned char*)data {
	Camera::pushCameraImage(len, data);
}

- (void)startLocation {
	[locationHelper startLocationUpdates];
}

- (void)stopLocation {
	[locationHelper stopLocationUpdates];
}

- (void)SetGpsDataIOS:(CLLocation *)newLocation {
	GPS::setGpsData((long long)newLocation.timestamp.timeIntervalSince1970,
					newLocation.horizontalAccuracy/5.0,
					newLocation.coordinate.latitude, newLocation.coordinate.longitude,
					newLocation.altitude,
					MAX(newLocation.speed * 3.6, 0.0), /* m/s to km/h */
					0 /* bearing */);
}

// The below is inspired by https://stackoverflow.com/questions/7253477/how-to-display-the-iphone-ipad-keyboard-over-a-full-screen-opengl-es-app
// It's a bit limited but good enough.

-(void) deleteBackward {
	KeyInput input{};
	input.deviceId = DEVICE_ID_KEYBOARD;
	input.flags = KEY_DOWN | KEY_UP;
	input.keyCode = NKCODE_DEL;
	NativeKey(input);
	INFO_LOG(SYSTEM, "Backspace");
}

-(void) insertText:(NSString *)text
{
	std::string str = std::string([text UTF8String]);
	INFO_LOG(SYSTEM, "Chars: %s", str.c_str());
	UTF8 chars(str);
	while (!chars.end()) {
		uint32_t codePoint = chars.next();
		INFO_LOG(SYSTEM, "Codepoint#: %d", codePoint);
		KeyInput input{};
		input.deviceId = DEVICE_ID_KEYBOARD;
		input.flags = KEY_CHAR;
		input.unicodeChar = codePoint;
		NativeKey(input);
	}
}

-(BOOL) canBecomeFirstResponder
{
	return true;
}

-(BOOL) hasText
{
	return true;
}

-(void) showKeyboard {
	dispatch_async(dispatch_get_main_queue(), ^{
		INFO_LOG(SYSTEM, "becomeFirstResponder");
		[self becomeFirstResponder];
	});
}

-(void) hideKeyboard {
	dispatch_async(dispatch_get_main_queue(), ^{
		INFO_LOG(SYSTEM, "resignFirstResponder");
		[self resignFirstResponder];
	});
}

@end

void bindDefaultFBO()
{
	[sharedViewController bindDefaultFBO];
}

void EnableFZ(){};
void DisableFZ(){};
