/*
 * KotinosOS motion.
 *
 * One timing language for every window transition, so the desktop moves like a
 * single object rather than a collection of independently-animated parts.
 *
 * WHY THESE CURVES
 *
 * macOS feels fluid because its motion is spring-driven: things leave fast and
 * settle slowly, and nothing moves at a constant speed. Linear motion is the
 * single biggest tell that an interface is animating rather than *moving*.
 *
 * True spring physics recomputes from the current velocity when an animation is
 * interrupted, so a window grabbed mid-flight continues smoothly instead of
 * snapping. KWin's scripting API cannot express that -- it animates on fixed
 * duration plus easing curve, and real spring behaviour needs a C++ effect
 * written against the animation API. That remains open work.
 *
 * What this achieves is the *perceptual* signature of spring motion: a fast
 * departure and a long, gentle settle, applied consistently. That is most of
 * the felt difference, and it is honest to call it spring-like easing rather
 * than spring physics.
 *
 * WHY ONE FILE
 *
 * The durations and curves below are the whole motion system. Anything added
 * later should reuse these constants rather than pick its own, or the desktop
 * stops feeling like one thing.
 */

"use strict";

// Motion constants. Everything animated by KotinosOS reads from here.
const Motion = {
    // Fast enough to feel immediate, slow enough to read as motion rather than
    // a jump. Below ~120ms the eye registers a cut; past ~350ms it feels sluggish.
    durationFast: 140,
    durationBase: 220,
    durationSlow: 300,

    // OutQuint: very fast start, long deceleration. The closest single curve to
    // a critically-damped spring, and it never overshoots -- overshoot on
    // *every* window would read as bouncy and cheap rather than lively.
    curveSettle: QEasingCurve.OutQuint,

    // For things leaving the screen, where the eye does not need to track the
    // ending precisely.
    curveExit: QEasingCurve.InQuad,

    // Scale a window starts from when appearing. Deliberately subtle: large
    // scale jumps draw attention to the animation instead of the window.
    appearScale: 0.94,
};

/*
 * Windows that should never animate.
 *
 * Animating these is actively harmful: menus and tooltips need to appear
 * instantly under the cursor, and desktop/dock surfaces are structural rather
 * than transient. Getting this wrong makes an interface feel laggy even though
 * every individual animation is smooth.
 */
function shouldAnimate(window) {
    if (!window) return false;
    if (window.desktopWindow || window.dock) return false;
    if (window.popupWindow || window.dropdownMenu || window.popupMenu) return false;
    if (window.tooltip || window.notification || window.criticalNotification) return false;
    if (window.splash || window.toolbar) return false;
    // Only animate things the user actually perceives as windows.
    return window.normalWindow || window.dialog;
}

function animateAppear(window) {
    if (!shouldAnimate(window)) return;

    animate({
        window: window,
        duration: Motion.durationBase,
        animations: [
            {
                type: Effect.Opacity,
                curve: Motion.curveSettle,
                from: 0.0,
                to: 1.0,
            },
            {
                type: Effect.Scale,
                curve: Motion.curveSettle,
                from: Motion.appearScale,
                to: 1.0,
            },
        ],
    });
}

function animateDisappear(window) {
    if (!shouldAnimate(window)) return;

    // Leaving is quicker than arriving. Waiting for something you have already
    // dismissed is the most irritating kind of animation.
    animate({
        window: window,
        duration: Motion.durationFast,
        animations: [
            {
                type: Effect.Opacity,
                curve: Motion.curveExit,
                from: 1.0,
                to: 0.0,
            },
            {
                type: Effect.Scale,
                curve: Motion.curveExit,
                from: 1.0,
                to: Motion.appearScale,
            },
        ],
    });
}

effects.windowAdded.connect(animateAppear);
effects.windowClosed.connect(animateDisappear);
effects.windowUnminimized.connect(animateAppear);
effects.windowMinimized.connect(animateDisappear);
