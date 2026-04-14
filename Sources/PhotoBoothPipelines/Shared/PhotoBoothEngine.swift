// PhotoBoothEngine.swift
// High-level orchestrator that ties together the camera pipeline, filter chain,
// adaptive quality, recording, and capture modes into a single API surface.
//
// This is the main entry point for integrating the Metal pipeline into a photo booth app.

import Foundation
import Metal
import MetalKit
import AVFoundation

/// The main photo booth engine. Manages the full lifecycle of camera capture,
/// real-time effects processing, recording, and still capture.
///
/// ## Quick Start
/// ```swift
/// let engine = PhotoBoothEngine()
///
/// // Configure effects
/// engine.applyPreset(.vintageFilm)
///
/// // Attach to a view
/// engine.attachPreview(to: mtkView)
///
/// // Start
/// engine.start()
///
/// // Capture a photo strip
/// engine.capturePhotoStrip { image in
///     // Save or display the photo strip image.
/// }
/// ```
public final class PhotoBoothEngine {

    // MARK: - Preset Effects

    public enum EffectPreset {
        case none
        case vintageFilm
        case glamourGlow
        case cinematic
        case boldPop
        case softDream
        case custom(filters: [MetalFilter])
    }

    // MARK: - Public Properties

    public let context: MetalContext
    public let cameraPipeline: CameraMetalPipeline
    public let qualityController: AdaptiveQualityController
    public let photoStripCapture: PhotoStripCapture
    public let gifExporter: GIFExporter
    public let boomerangCapture: BoomerangCapture
    public let videoRecorder: MetalVideoRecorder

    /// Current FPS.
    public var fps: Double { cameraPipeline.measuredFPS }

    /// GPU memory usage.
    public var gpuMemoryMB: Double { Double(context.currentAllocatedSize) / 1_048_576.0 }

    // MARK: - Init

    public init() {
        self.context = .shared
        self.cameraPipeline = CameraMetalPipeline(context: context)
        self.qualityController = AdaptiveQualityController(targetFPS: 30)
        self.photoStripCapture = PhotoStripCapture(context: context)
        self.gifExporter = GIFExporter(context: context)
        self.boomerangCapture = BoomerangCapture(context: context)
        self.videoRecorder = MetalVideoRecorder(width: 1920, height: 1080, context: context)

        // Set up debug capture scope.
        MetalDebugCapture.shared.setup(device: context.device)

        // Wire up adaptive quality.
        qualityController.onQualityChange = { [weak self] quality in
            guard let self = self else { return }
            self.qualityController.apply(to: self.cameraPipeline.filterChain)
            print("[PhotoBoothEngine] Quality adjusted to: \(quality)")
        }
    }

    // MARK: - Lifecycle

    public func start() {
        cameraPipeline.start()
    }

    public func stop() {
        cameraPipeline.stop()
    }

    public func attachPreview(to view: MTKView) {
        cameraPipeline.attachPreview(to: view)
    }

    // MARK: - Effect Presets

    public func applyPreset(_ preset: EffectPreset) {
        let chain = cameraPipeline.filterChain
        chain.removeAll()

        switch preset {
        case .none:
            break

        case .vintageFilm:
            let vintage = VintageFilter(context: context)
            vintage.grainIntensity = 0.12
            vintage.sepiaStrength = 0.35
            vintage.saturation = 0.65
            chain.append(vintage)

            let vignette = VignetteFilter(context: context)
            vignette.intensity = 0.6
            vignette.radius = 0.35
            chain.append(vignette)

        case .glamourGlow:
            let bloom = BloomFilter(context: context)
            bloom.threshold = 0.5
            bloom.intensity = 0.6
            bloom.blurRadius = 12
            chain.append(bloom)

            let vignette = VignetteFilter(context: context)
            vignette.intensity = 0.4
            chain.append(vignette)

        case .cinematic:
            // Cinematic look: color grading + vignette + subtle bloom.
            let colorGrade = ColorGradeFilter(context: context)
            colorGrade.loadLUT(named: "cinematic_lut")
            colorGrade.intensity = 0.8
            chain.append(colorGrade)

            let bloom = BloomFilter(context: context)
            bloom.threshold = 0.75
            bloom.intensity = 0.3
            chain.append(bloom)

            let vignette = VignetteFilter(context: context)
            vignette.intensity = 0.5
            chain.append(vignette)

        case .boldPop:
            // High contrast, vibrant colour — no desaturation.
            let vintage = VintageFilter(context: context)
            vintage.grainIntensity = 0.0
            vintage.sepiaStrength = 0.0
            vintage.saturation = 1.3  // Over-saturate
            vintage.fadeAmount = 0.0
            vintage.vignetteAmount = 0.0
            chain.append(vintage)

        case .softDream:
            let blur = GaussianBlurFilter(context: context)
            blur.radius = 4
            chain.append(blur)

            let bloom = BloomFilter(context: context)
            bloom.threshold = 0.4
            bloom.intensity = 0.7
            chain.append(bloom)

            let vignette = VignetteFilter(context: context)
            vignette.intensity = 0.3
            vignette.softness = 0.6
            chain.append(vignette)

        case .custom(let filters):
            for filter in filters {
                chain.append(filter)
            }
        }
    }

    // MARK: - Overlay

    /// Add a template overlay on top of all effects.
    public func setOverlay(named imageName: String, blendMode: OverlayFilter.BlendMode = .normal, opacity: Float = 1.0) {
        // Remove existing overlay filters.
        let chain = cameraPipeline.filterChain
        chain.filters.removeAll { $0 is OverlayFilter }

        let overlay = OverlayFilter(context: context)
        overlay.loadOverlay(named: imageName)
        overlay.blendMode = blendMode
        overlay.opacity = opacity
        chain.append(overlay)
    }

    /// Add an animated sprite-sheet overlay.
    public func setAnimatedOverlay(named imageName: String,
                                   columns: Int, rows: Int, fps: Double = 12.0,
                                   blendMode: OverlayFilter.BlendMode = .screen,
                                   opacity: Float = 0.8) {
        let chain = cameraPipeline.filterChain
        chain.filters.removeAll { $0 is OverlayFilter }

        let overlay = OverlayFilter(context: context)
        overlay.loadOverlay(named: imageName)
        overlay.spriteColumns = columns
        overlay.spriteRows = rows
        overlay.animationFPS = fps
        overlay.blendMode = blendMode
        overlay.opacity = opacity
        chain.append(overlay)
    }

    // MARK: - Memory Management

    /// Call on `UIApplication.didReceiveMemoryWarningNotification`.
    public func handleMemoryWarning() {
        cameraPipeline.filterChain.handleMemoryWarning()
        context.flushTextureCache()
    }
}
