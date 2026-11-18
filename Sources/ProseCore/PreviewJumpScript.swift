import Foundation

/// What the preview does with the next source jump Tinymist sends it.
public enum PreviewJumpMark: String, Sendable {
    /// Scroll to the spot as usual and mark it with the glow.
    case glow
    /// Mark the spot with the glow. Scroll only when the spot is out of view.
    case glowIfHidden

    /// The call that tells the page to mark the next jump.
    public var javaScript: String {
        "window.proseMarkNextJump?.('\(rawValue)') ?? false"
    }
}

/// Lets the preview's web view mark the next jump before Prose asks Tinymist for it.
@MainActor
public protocol PreviewJumpMarking: AnyObject {
    func markNextJump(_ mark: PreviewJumpMark) async
}

public extension PreviewScripts {
    /// The glow's diameter in points.
    static let jumpGlowSize = 32
    /// The glow's fade, in milliseconds.
    static let jumpGlowFadeMilliseconds = 900
    /// With Reduce Motion, the glow shows still for this long, in milliseconds.
    static let jumpGlowStillMilliseconds = 600
    /// A mark waits this long for its jump, in milliseconds. Tinymist sends
    /// no jump when the caret is on something it cannot place.
    static let jumpMarkLifetimeMilliseconds = 2000
    /// The accent colour: dusk violet, lighter for dark reading (spec Section 4).
    static let jumpGlowLight = "#7C2494"
    static let jumpGlowDark = "#B784E0"

    /// The glow that marks where a click in the text lands in the preview.
    /// Tinymist's page calls `impl.scrollTo(pageWidth, page, left, top)` for a
    /// jump, where `left` and `top` are CSS pixels from the corner of the
    /// document's SVG. The wrapper in `setup` asks `window.proseJumpMark`
    /// first; it draws the glow there and says whether to skip the scroll.
    static var jumpGlow: String {
        """
        ;(() => {
            const glowStyle = document.createElement('style');
            // Tinymist draws a small teal ring at every jump. The glow replaces
            // it, and shows only for a jump Prose marked.
            glowStyle.textContent = `
                .typst-jump-ripple { display: none !important; }
                .prose-jump-glow {
                    position: fixed; z-index: 2147483647; pointer-events: none;
                    width: \(jumpGlowSize)px; height: \(jumpGlowSize)px;
                    margin: -\(jumpGlowSize / 2)px 0 0 -\(jumpGlowSize / 2)px;
                    border-radius: 50%; opacity: 0;
                }
            `;
            document.head.appendChild(glowStyle);
            let pending = null;
            window.proseMarkNextJump = mode => {
                if (mode !== 'glow' && mode !== 'glowIfHidden') return false;
                pending = {mode, until: performance.now() + \(jumpMarkLifetimeMilliseconds), drawn: false};
                return true;
            };
            const accent = () => window.prosePreviewDark ? '\(jumpGlowDark)' : '\(jumpGlowLight)';
            const reduceMotion = () => {
                try { return window.matchMedia('(prefers-reduced-motion: reduce)').matches; } catch { return false; }
            };
            const glow = (doc, left, top) => {
                const element = document.createElement('div');
                element.className = 'prose-jump-glow';
                const color = accent();
                element.style.background = `radial-gradient(circle, ${color}73 0%, ${color}40 45%, ${color}00 70%)`;
                element.style.boxShadow = `0 0 12px ${color}59`;
                // The page may scroll to the spot after the glow appears. Keep
                // the glow on the spot by placing it from the document each frame.
                let alive = true;
                const place = () => {
                    if (!alive) return;
                    const box = doc.getBoundingClientRect();
                    element.style.left = `${box.left + left}px`;
                    element.style.top = `${box.top + top}px`;
                    requestAnimationFrame(place);
                };
                const remove = () => { alive = false; element.remove(); };
                place();
                document.body.appendChild(element);
                if (reduceMotion() || typeof element.animate !== 'function') {
                    element.style.opacity = '1';
                    setTimeout(remove, \(jumpGlowStillMilliseconds));
                    return;
                }
                const fade = element.animate([
                    {opacity: 0, transform: 'scale(0.6)'},
                    {opacity: 1, transform: 'scale(1)', offset: 0.15},
                    {opacity: 0, transform: 'scale(1.15)'}
                ], {duration: \(jumpGlowFadeMilliseconds), easing: 'ease-out'});
                fade.onfinish = remove;
                fade.oncancel = remove;
                // A page in the background may never finish the animation.
                setTimeout(remove, \(jumpGlowFadeMilliseconds) + 500);
            };
            // Returns true when the page should not scroll for this jump.
            window.proseJumpMark = (impl, args) => {
                try {
                    if (!pending) return false;
                    if (performance.now() > pending.until) { pending = null; return false; }
                    const mark = pending;
                    // Tinymist calls scrollTo once per document in the same task.
                    setTimeout(() => { if (pending === mark) pending = null; }, 0);
                    const [, , left, top] = args;
                    const doc = impl?.hookedElem?.querySelector?.('.typst-doc');
                    if (!doc || !Number.isFinite(left) || !Number.isFinite(top)) return false;
                    if (!mark.drawn) { mark.drawn = true; glow(doc, left, top); }
                    if (mark.mode !== 'glowIfHidden') return false;
                    const host = impl.hookedElem.parentElement;
                    if (!host) return false;
                    const box = doc.getBoundingClientRect(), view = host.getBoundingClientRect();
                    const x = box.left + left, y = box.top + top, inset = \(jumpGlowSize / 2);
                    return x >= view.left + inset && x <= view.left + host.clientWidth - inset &&
                        y >= view.top + inset && y <= view.top + host.clientHeight - inset;
                } catch { return false; }
            };
        })();
        """
    }
}
