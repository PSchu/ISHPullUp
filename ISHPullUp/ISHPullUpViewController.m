//
//  ISHPullUpViewController.m
//  ISHPullUp
//
//  Created by Felix Lamouroux on 25.06.16.
//  Copyright © 2016 iosphere GmbH. All rights reserved.
//

#import "ISHPullUpViewController.h"
#import "ISHPullUpRoundedView.h"

const CGFloat ISHPullUpViewControllerDefaultMinimumHeight = 55.0;
const CGFloat ISHPullUpViewControllerDefaultSnapThreshold = 0.25;
const CGFloat ISHPullUpViewControllerDefaultTopMargin = 20.0;

@interface ISHPullUpViewController ()<UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIPanGestureRecognizer *panGesture;
@property (nonatomic) CGFloat bottomHeight;
@property (nonatomic) CGFloat bottomHeightAtStartOfGesture;
@property (nonatomic) ISHPullUpState stateAtStartOfGesture;
@property (nonatomic) CGFloat minimumBottomHeightCached;
@property (nonatomic) CGFloat maximumBottomHeightCached;
@property (nonatomic) BOOL firstAppearCompleted;
@property (nonatomic) BOOL didAppearCompleted;
@property (nonatomic) BOOL isAnimatingStateChange;
@property (nonatomic, readwrite) BOOL bottomHidden;
@end

@implementation ISHPullUpViewController

- (instancetype)init {
    self = [super init];
    [self setupPropertyDefaults];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    [self setupPropertyDefaults];
    return self;
}

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    [self setupPropertyDefaults];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupPropertyDefaults {
    // set default layout mode without calling setter to avoid premature layout calls 
    _bottomLayoutMode = ISHPullUpBottomLayoutModeShift;
    self.bottomHeight = ISHPullUpViewControllerDefaultMinimumHeight;
    self.snapToEnds = YES;
    self.snapThreshold = ISHPullUpViewControllerDefaultSnapThreshold;
    self.topMargin = ISHPullUpViewControllerDefaultTopMargin;
    self.bottomHiddenMargin = 10.0;

    ISHPullUpAnimationConfiguration config;
    config.duration = 0.4;
    config.springDamping = 0.9;
    config.initialVelocity = 0.3;
    config.options = UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionLayoutSubviews;
    self.animationConfiguration = config;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self addViewOfSubViewController:self.bottomViewController belowView:nil];
    [self addViewOfSubViewController:self.contentViewController belowView:self.bottomViewController.view];
    [self setupPanGestureRecognizerForViewController:self.bottomViewController];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(UIApplicationDidChangeStatusBarFrameNotification:)
                                                 name:UIApplicationDidChangeStatusBarFrameNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    if (!self.firstAppearCompleted) {
        [self updateCachedHeightsWithSize:self.view.bounds.size];
        self.bottomHeight = self.minimumBottomHeightCached;
        [self updateViewLayoutBottomHeight:self.bottomHeight withSize:self.view.bounds.size];

        // update to current state
        [self.stateDelegate pullUpViewController:self didChangeToState:self.state];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self setFirstAppearCompleted:YES];
    [self setDidAppearCompleted:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self setDidAppearCompleted:NO];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (!self.didAppearCompleted) {
        // in case there was a rotation event while hidden,
        // this is the earliest opportunity to fix the layout

        [self invalidateLayout];
    }
}

- (void)setLocked:(BOOL)locked {
    _locked = locked;
    [self updateGestureEnabledState];
}

- (void)updateGestureEnabledState {
    self.panGesture.enabled = !self.locked && !self.bottomHidden;
}

#pragma mark Pan Gesture

- (void)setupPanGestureRecognizerForViewController:(UIViewController *)vc {
    // remove previous gesture recognizer if needed
    [self.panGesture.view removeGestureRecognizer:self.panGesture];

    // setup new gesture recognizer on vc's view
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanGesture:)];
    self.panGesture = panGesture;
    panGesture.delegate = self;
    [self updateGestureEnabledState];
    [vc.view addGestureRecognizer:panGesture];
}

- (void)handlePanGesture:(UIPanGestureRecognizer *)gesture {
    BOOL animated = NO;
    CGFloat newHeight;

    switch (gesture.state) {
        case UIGestureRecognizerStatePossible:
            return;

        case UIGestureRecognizerStateBegan:
            self.bottomHeightAtStartOfGesture = self.bottomHeight;
            self.stateAtStartOfGesture = [self state];
            [self.stateDelegate pullUpViewController:self didChangeToState:self.stateAtStartOfGesture];
            [self updateCachedHeightsWithSize:self.view.bounds.size];
            return; // no change in layout

        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateChanged:
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateFailed: {
            CGPoint translation = [gesture translationInView:self.view];
            CGFloat targetHeight = self.bottomHeightAtStartOfGesture - translation.y;
            CGFloat maxHeight = self.maximumBottomHeightCached;
            // if above minimum -> add friction
            if (targetHeight > maxHeight) {
                CGFloat portionAboveMax = targetHeight - maxHeight;
                CGFloat maxOvershoot = 100.0;
                targetHeight = maxHeight + maxOvershoot * tanh(portionAboveMax / (maxOvershoot * 3.0));
            }

            // clip above minimum
            newHeight = MAX(self.minimumBottomHeightCached, targetHeight);

            if (gesture.state == UIGestureRecognizerStateChanged) {
                break;
            }

            // Gesture ended:
            // clip to maximum
            newHeight = MIN(self.maximumBottomHeightCached, newHeight);

            // allow sizing delegate to select other target height
            if (self.sizingDelegate && self.bottomViewController) {
                newHeight = [self.sizingDelegate pullUpViewController:self targetHeightForBottomViewController:self.bottomViewController fromCurrentHeight:newHeight];
                animated = YES;
            }

            if (!self.snapToEnds) {
                break;
            }

            // snap to top/bottom
            NSAssert(self.snapThreshold > 0, @"Snapthreshold should be positive.");
            NSAssert(self.snapThreshold < 1, @"Snapthreshold should be smaller than 1.");
            if (newHeight > self.maximumBottomHeightCached * (1 - self.snapThreshold)) {
                newHeight = self.maximumBottomHeightCached;
                animated = YES;
            } else if (self.minimumBottomHeightCached + self.maximumBottomHeightCached * self.snapThreshold > newHeight) {
                newHeight = self.minimumBottomHeightCached;
                animated = YES;
            }

            break;
        }
    }

    [self setBottomHeight:newHeight animated:animated];

    ISHPullUpState currentState = [self state];

    if (currentState != self.stateAtStartOfGesture) {
        [self.stateDelegate pullUpViewController:self didChangeToState:currentState];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    NSAssert(gestureRecognizer == self.panGesture, @"Unexpected gesture recognizer: %@", gestureRecognizer);

    // Do not interfere with scrollviews
    return NO;
}

#pragma mark Content and PullUp VC

- (void)setContentViewController:(UIViewController *)contentViewController {
    if (contentViewController == _contentViewController) {
        return;
    }

    if (_contentViewController.parentViewController == self) {
        // remove previous content VC if it was already added (and we are still the parent)
        [self removeSubViewController:_contentViewController];
    }

    _contentViewController = contentViewController;
    // insert contentViewController's view below dimming view or bottomViewController.view if any of those are loaded
    [self addViewOfSubViewController:_contentViewController belowView: self.bottomViewController.view];
}

- (void)setBottomViewController:(UIViewController *)bottomViewController {
    if (bottomViewController == _bottomViewController) {
        return;
    }

    if (_bottomViewController.parentViewController == self) {
        // remove previous bottom VC if it was already added (and we are still the parent)
        [self removeSubViewController:_bottomViewController];
    }

    _bottomViewController = bottomViewController;
    [self addViewOfSubViewController:_bottomViewController belowView:nil];

    if (self.isViewLoaded) {
        [self setupPanGestureRecognizerForViewController:bottomViewController];
        [self updateCachedHeightsWithSize:self.view.bounds.size];
        
        if (self.bottomHeight > self.maximumBottomHeightCached) {
            [self setState:ISHPullUpStateExpanded animated:YES];
        } else {
            [self updateViewLayoutBottomHeight:self.bottomHeight withSize:self.view.bounds.size];
        }
    }
}

#pragma mark State

- (ISHPullUpState)state {
    UIGestureRecognizerState gestureState = self.panGesture.state;
    BOOL gestureIsDragging = (gestureState == UIGestureRecognizerStateBegan) || (gestureState == UIGestureRecognizerStateChanged);

    if (gestureIsDragging || self.isAnimatingStateChange) {
        return ISHPullUpStateDragging;
    }

    CGFloat bottomHeight = self.bottomHeight;

    if (bottomHeight <= [self minimumBottomHeight]) {
        return ISHPullUpStateCollapsed;
    }

    if (bottomHeight >= [self maximumBottomHeightWithSize:self.view.bounds.size]) {
        return ISHPullUpStateExpanded;
    }

    return ISHPullUpStateIntermediate;
}

- (void)setState:(ISHPullUpState)state animated:(BOOL)animated {
    ISHPullUpState oldState = [self state];

    BOOL stateChanges = (state != oldState);

    NSAssert(state != ISHPullUpStateIntermediate, @"Setting an intermediate state has no effect.");
    NSAssert(state != ISHPullUpStateDragging, @"Setting a dragging state has no effect.");
    CGFloat newHeight;
    [self updateCachedHeightsWithSize:self.view.bounds.size];
    switch (state) {
        case ISHPullUpStateExpanded:
            newHeight = self.maximumBottomHeightCached;
            break;

        case ISHPullUpStateCollapsed:
            newHeight = self.minimumBottomHeightCached;
            break;

        case ISHPullUpStateIntermediate:
        case ISHPullUpStateDragging:
            // no effect
            return;
    }

    [self setBottomHeight:newHeight animated:animated];
    if (stateChanges) {
        [self.stateDelegate pullUpViewController:self didChangeToState:state];
    }
}

- (void)toggleStateAnimated:(BOOL)animated {
    BOOL isCollapsed = (self.state == ISHPullUpStateCollapsed);
    [self setState:isCollapsed ? ISHPullUpStateExpanded : ISHPullUpStateCollapsed
          animated:animated];
}

#pragma mark Layout

- (void)setBottomLayoutMode:(ISHPullUpBottomLayoutMode)bottomLayoutMode {
    if (bottomLayoutMode == _bottomLayoutMode) {
        return;
    }

    _bottomLayoutMode = bottomLayoutMode;
    [self updateViewLayoutBottomHeight:self.bottomHeight withSize:self.view.bounds.size];
}

- (void)invalidateLayout {
    [self updateCachedHeightsWithSize:self.view.bounds.size];
    // clamp bottom height to new min/max
    self.bottomHeight = MAX(self.minimumBottomHeightCached, MIN(self.bottomHeight, self.maximumBottomHeightCached));
    [self updateViewLayoutBottomHeight:self.bottomHeight withSize:self.view.bounds.size];
}

- (CGFloat)minimumBottomHeight {
    if (!self.bottomViewController) {
        return 0;
    }

    if (!self.sizingDelegate) {
        return ISHPullUpViewControllerDefaultMinimumHeight;
    }

    return [self.sizingDelegate pullUpViewController:self minimumHeightForBottomViewController:self.bottomViewController];
}

- (CGFloat)maximumAvailableHeightWithSize:(CGSize)size {
    return size.height - self.topLayoutGuide.length - self.topMargin;
}

- (CGFloat)maximumBottomHeightWithSize:(CGSize)size  {
    CGFloat maximumAvailableHeight = [self maximumAvailableHeightWithSize:size];

    if (!self.sizingDelegate || !self.bottomViewController) {
        return maximumAvailableHeight;
    }

    return MIN(maximumAvailableHeight, [self.sizingDelegate pullUpViewController:self maximumHeightForBottomViewController:self.bottomViewController maximumAvailableHeight:maximumAvailableHeight]);
}

- (void)updateCachedHeightsWithSize:(CGSize)size  {
    self.minimumBottomHeightCached = [self minimumBottomHeight];
    self.maximumBottomHeightCached = [self maximumBottomHeightWithSize:size];
}

- (void)setBottomHidden:(BOOL)bottomHidden animated:(BOOL)animated {
    if (!bottomHidden == !_bottomHidden) {
        return;
    }

    _bottomHidden = bottomHidden;
    [self updateGestureEnabledState];

    UIViewController *bottomVC = self.bottomViewController;

    if (!bottomHidden) {
        bottomVC.view.hidden = NO;
        [bottomVC viewWillAppear:animated];
    } else {
        [bottomVC viewWillDisappear:animated];
    }

    void (^updateBlock)() = ^{
        [self updateViewLayoutBottomHeight:self.bottomHeight withSize:self.view.bounds.size];
    };

    __weak ISHPullUpViewController *weakSelf = self;
    void (^completion)(BOOL) = ^(BOOL finished) {
        ISHPullUpViewController *strongSelf = weakSelf;
        if (!finished || !strongSelf) {
            return;
        }

        if (bottomHidden) {
            [strongSelf.bottomViewController viewDidDisappear:animated];
            [strongSelf.bottomViewController.view setHidden:YES];
        } else {
            [strongSelf.bottomViewController viewDidAppear:animated];
        }
    };

    if (animated) {
        [[self class] springAnimationWithConfig:self.animationConfiguration
                                     animations:updateBlock
                                     completion:completion];
    } else {
        updateBlock();
        completion(YES);
    }
}

+ (void)springAnimationWithConfig:(ISHPullUpAnimationConfiguration)config animations:(void (^)(void))animations completion:(void (^__nullable)(BOOL finished))completion {
    NSAssert(config.options & UIViewAnimationOptionLayoutSubviews, @"Animation options must always contain UIViewAnimationOptionLayoutSubviews");

    [UIView animateWithDuration:config.duration
                          delay:0
         usingSpringWithDamping:config.springDamping
          initialSpringVelocity:config.initialVelocity
                        options:config.options
                     animations:animations
                     completion:completion];
}

- (void)setBottomHeight:(CGFloat)bottomHeight animated:(BOOL)animated {
    if (bottomHeight == self.bottomHeight) {
        return;
    }

    self.bottomHeight = bottomHeight;

    void (^updateBlock)();
    updateBlock = ^{
        self.isAnimatingStateChange = animated;

        // setup (hide) dimming view with oldheight
        // this allows the animation to start from the old height and animate along
        [self updateViewLayoutBottomHeight:bottomHeight withSize:self.view.bounds.size];

        if (animated) {
            // when animating, we need an intermediate state
            [self.stateDelegate pullUpViewController:self didChangeToState:[self state]];
        }
    };

    if (!animated) {
        updateBlock();
        return;
    }

    __weak ISHPullUpViewController *weakSelf = self;
    [[self class] springAnimationWithConfig:self.animationConfiguration
                                 animations:updateBlock
                                 completion:^(BOOL finished) {
                                     ISHPullUpViewController *strongSelf = weakSelf;
                                     if (!strongSelf) {
                                         return;
                                     }
                                     strongSelf.isAnimatingStateChange = NO;
                                     [strongSelf.stateDelegate pullUpViewController:strongSelf didChangeToState:[strongSelf state]];
                                 }];
}

- (void)updateViewLayoutBottomHeight:(CGFloat)bottomHeight withSize:(CGSize)size {
    if (!self.isViewLoaded) {
        // avoid loading the view controllers' views prematurely
        return;
    }
    CGFloat clampedBottomHeight = MAX(bottomHeight, self.minimumBottomHeightCached);
    CGRect bounds = CGRectMake(0, 0, size.width, size.height);

    // content fills entire view
    [self.contentViewController.view setFrame:bounds];

    CGRect bottomFrame = CGRectZero;
    switch (self.bottomLayoutMode) {
        case ISHPullUpBottomLayoutModeShift: {
            /*
             *   we do not resize the bottomView controller below its maximum height:
             *   - this avoids artefacts in included scrollviews while dragging
             *   - this also improves scroll performance
             */
            CGFloat maxHeight = self.maximumBottomHeightCached;
            CGFloat expandedBottomHeight = MAX(maxHeight, clampedBottomHeight);
            CGFloat yPosition = CGRectGetMaxY(bounds) - clampedBottomHeight - self.bottomLayoutGuide.length;

            bottomFrame = CGRectMake(0, yPosition, CGRectGetWidth(bounds), expandedBottomHeight);
            break;
        }

        case ISHPullUpBottomLayoutModeResize: {
            clampedBottomHeight = bottomHeight;
            CGFloat yPosition = CGRectGetMaxY(bounds) - clampedBottomHeight - self.bottomLayoutGuide.length;

            bottomFrame = CGRectMake(0, yPosition, CGRectGetWidth(bounds), clampedBottomHeight);
            break;
        }
    }

    if (self.bottomHidden) {
        // hide the bottom view by moving the view below the view and add the bottomHiddenMargin
        bottomFrame = CGRectOffset(bottomFrame, 0, size.height - bottomFrame.origin.y + self.bottomHiddenMargin);
    }

    [self.bottomViewController.view setFrame:bottomFrame];

    // inform content delegate that edge insets were updated
    if (self.contentViewController) {
        [self.contentDelegate pullUpViewController:self
                                  updateEdgeInsets:UIEdgeInsetsMake(0, 0, clampedBottomHeight, 0)
                          forContentViewController:self.contentViewController];
    }
    
    if (self.bottomViewController && (self.bottomLayoutMode == ISHPullUpBottomLayoutModeShift)) {
        [self.sizingDelegate pullUpViewController:self
                                 updateEdgeInsets:UIEdgeInsetsMake(0, 0, self.maximumBottomHeightCached - clampedBottomHeight, 0)
                          forBottomViewController:self.bottomViewController];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    ISHPullUpState stateBefore = [self state];
    [coordinator animateAlongsideTransition:^(id < UIViewControllerTransitionCoordinatorContext > _Nonnull context) {
        [self updateCachedHeightsWithSize:size];
        self.bottomHeight = MAX(MIN(self.bottomHeight, self.maximumBottomHeightCached), self.minimumBottomHeightCached);
        [self updateViewLayoutBottomHeight:self.bottomHeight withSize:size];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> _Nonnull context) {
        // snap back to previous state if in one of the end positions
        if ((stateBefore == ISHPullUpStateCollapsed) || (stateBefore == ISHPullUpStateExpanded)) {
            [self setState:stateBefore animated:context.isAnimated];
        }
    }];
}

- (void)UIApplicationDidChangeStatusBarFrameNotification:(NSNotification *)note {
    [UIView animateWithDuration:0.25 animations:^{
        [self invalidateLayout];
    }];
}

#pragma mark VC Hierachry

- (void)addViewOfSubViewController:(UIViewController *)vc belowView:(nullable UIView *)belowView{
    if (!vc || !self.isViewLoaded || vc.view.superview || vc.parentViewController) {
        // do nothing if
        // - our view has not yet been loaded (will be called later again)
        // - vc.view has already a super view
        // - vc already a parent
        NSAssert(!(vc.isViewLoaded && vc.view.superview), @"addViewOfSubViewController: should not be called for view controllers who's views have already been added to the view hierarchy.");
        NSAssert(!vc.parentViewController, @"addViewOfSubViewController: should not be called for view controllers already have a parent view controller");
        return;
    }

    [self addChildViewController:vc];
    if ([belowView isDescendantOfView:self.view]) {
        [self.view insertSubview:vc.view belowSubview:belowView];
    } else {
        [self.view addSubview:vc.view];
    }

    [self updateViewLayoutBottomHeight:self.bottomHeight withSize:self.view.bounds.size];
    [vc didMoveToParentViewController:self];
}

- (void)removeSubViewController:(UIViewController *)vc {
    if (vc.parentViewController != self) {
        NSAssert(vc.parentViewController == self, @"removeSubViewController should only be used for child view controllers.");
        return;
    }

    [vc willMoveToParentViewController:nil];
    [vc.view removeFromSuperview];
    [vc removeFromParentViewController];
}

#pragma mark Dimming

// status bar should use light style if dimmed
- (UIStatusBarStyle)preferredStatusBarStyle {
    return self.contentViewController.preferredStatusBarStyle;
}
@end
