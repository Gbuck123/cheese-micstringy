/**
 * Photo Booth Template Serialization Schema
 *
 * This is the canonical format shared between:
 *   - The web-based template editor (React + fabric.js / Konva)
 *   - The iPad renderer (Swift / Metal pipeline)
 *
 * Design principles:
 *   - Every element has a stable UUID for diffing/syncing
 *   - All coordinates are in logical pixels relative to the template canvas
 *   - Colors are 8-char hex (#RRGGBBAA) for consistency with both web and iOS
 *   - Fonts reference a font registry (Google Fonts ID or custom upload UUID)
 *   - The format is versioned so old templates can be migrated forward
 */

// ---------------------------------------------------------------------------
// Version & Metadata
// ---------------------------------------------------------------------------

export const TEMPLATE_SCHEMA_VERSION = 2;

export interface TemplateMetadata {
  /** Monotonically increasing schema version */
  schemaVersion: number;
  /** UUID of this template */
  id: string;
  /** Human-readable name */
  name: string;
  /** Optional description */
  description?: string;
  /** ISO-8601 creation timestamp */
  createdAt: string;
  /** ISO-8601 last-modified timestamp */
  updatedAt: string;
  /** UUID of the user who owns this template */
  ownerId: string;
  /** Tags for organization */
  tags: string[];
  /** Thumbnail URL (generated on save) */
  thumbnailUrl?: string;
}

// ---------------------------------------------------------------------------
// Canvas / Template Size
// ---------------------------------------------------------------------------

export type PresetSize =
  | '4x6'           // 1200 x 1800 px @ 300 DPI
  | '2x6_strip'     // 600 x 1800 px @ 300 DPI
  | '1080x1080'     // Instagram square
  | '1080x1920'     // Instagram story / TikTok
  | 'custom';

export interface CanvasSize {
  preset: PresetSize;
  /** Width in pixels */
  width: number;
  /** Height in pixels */
  height: number;
  /** DPI for print templates */
  dpi: number;
}

export const PRESET_SIZES: Record<Exclude<PresetSize, 'custom'>, CanvasSize> = {
  '4x6':        { preset: '4x6',        width: 1200, height: 1800, dpi: 300 },
  '2x6_strip':  { preset: '2x6_strip',  width: 600,  height: 1800, dpi: 300 },
  '1080x1080':  { preset: '1080x1080',  width: 1080, height: 1080, dpi: 72 },
  '1080x1920':  { preset: '1080x1920',  width: 1080, height: 1920, dpi: 72 },
};

// ---------------------------------------------------------------------------
// Color
// ---------------------------------------------------------------------------

/** 8-character hex color #RRGGBBAA */
export type HexColorAlpha = string;

export interface GradientStop {
  offset: number;  // 0..1
  color: HexColorAlpha;
}

export interface GradientFill {
  type: 'linear' | 'radial';
  angle?: number;      // degrees, for linear
  stops: GradientStop[];
}

export type Fill = HexColorAlpha | GradientFill;

// ---------------------------------------------------------------------------
// Font Reference
// ---------------------------------------------------------------------------

export interface FontReference {
  /** Font family name as it should appear in CSS / CoreText */
  family: string;
  /** Google Fonts identifier (if applicable) */
  googleFontId?: string;
  /** UUID of an uploaded custom font */
  customFontId?: string;
  /** URL to the font file (WOFF2 for web, TTF/OTF for iOS) */
  urls: {
    woff2?: string;
    ttf?: string;
    otf?: string;
  };
  /** Font weight (100-900) */
  weight: number;
  /** Font style */
  style: 'normal' | 'italic';
}

// ---------------------------------------------------------------------------
// Base Element
// ---------------------------------------------------------------------------

export interface BaseElement {
  /** Stable UUID */
  id: string;
  /** Element type discriminator */
  type: ElementType;
  /** Human-readable label for layers panel */
  name: string;
  /** Position relative to canvas origin (top-left) */
  x: number;
  y: number;
  /** Dimensions */
  width: number;
  height: number;
  /** Rotation in degrees (clockwise) */
  rotation: number;
  /** Opacity 0..1 */
  opacity: number;
  /** Z-index for ordering (higher = on top) */
  zIndex: number;
  /** Whether the element is locked (cannot be moved/resized) */
  locked: boolean;
  /** Whether the element is visible */
  visible: boolean;
  /** Blend mode */
  blendMode: BlendMode;
  /** Optional shadow */
  shadow?: ShadowConfig;
  /** Animation properties (for video templates) */
  animation?: AnimationConfig;
}

export type BlendMode =
  | 'normal'
  | 'multiply'
  | 'screen'
  | 'overlay'
  | 'darken'
  | 'lighten'
  | 'color-dodge'
  | 'color-burn'
  | 'soft-light'
  | 'hard-light';

export interface ShadowConfig {
  color: HexColorAlpha;
  blur: number;
  offsetX: number;
  offsetY: number;
}

// ---------------------------------------------------------------------------
// Animation (for Video Templates)
// ---------------------------------------------------------------------------

export type EasingFunction =
  | 'linear'
  | 'easeIn'
  | 'easeOut'
  | 'easeInOut'
  | 'spring';

export interface AnimationKeyframe {
  /** Time in seconds from template start */
  time: number;
  /** Properties to animate to */
  properties: Partial<{
    x: number;
    y: number;
    width: number;
    height: number;
    rotation: number;
    opacity: number;
    scaleX: number;
    scaleY: number;
  }>;
  easing: EasingFunction;
}

export interface AnimationConfig {
  /** Keyframes for this element's animation timeline */
  keyframes: AnimationKeyframe[];
  /** Delay before animation starts (seconds) */
  delay: number;
  /** Total duration of the animation (seconds) */
  duration: number;
  /** Whether the animation loops */
  loop: boolean;
}

// ---------------------------------------------------------------------------
// Concrete Element Types
// ---------------------------------------------------------------------------

export type ElementType =
  | 'text'
  | 'image'
  | 'shape'
  | 'photo_zone'
  | 'group';

// --- Text ---

export interface TextElement extends BaseElement {
  type: 'text';
  /** The text content */
  content: string;
  /** Font configuration */
  font: FontReference;
  /** Font size in pixels */
  fontSize: number;
  /** Text fill color or gradient */
  fill: Fill;
  /** Text alignment */
  textAlign: 'left' | 'center' | 'right';
  /** Vertical alignment */
  verticalAlign: 'top' | 'middle' | 'bottom';
  /** Line height multiplier */
  lineHeight: number;
  /** Letter spacing in pixels */
  letterSpacing: number;
  /** Text decoration */
  textDecoration: 'none' | 'underline' | 'line-through';
  /** Text transform */
  textTransform: 'none' | 'uppercase' | 'lowercase' | 'capitalize';
  /** Stroke / outline */
  stroke?: {
    color: HexColorAlpha;
    width: number;
  };
  /** Curved text (for circular/arc text) */
  curvedText?: {
    radius: number;
    /** Angle span in degrees */
    span: number;
  };
}

// --- Image ---

export interface ImageElement extends BaseElement {
  type: 'image';
  /** URL to the image asset (S3/CDN) */
  src: string;
  /** Asset UUID in the asset management system */
  assetId: string;
  /** Crop rectangle (relative to original image, 0..1) */
  crop?: {
    x: number;
    y: number;
    width: number;
    height: number;
  };
  /** Image filters */
  filters?: ImageFilters;
  /** Corner radius for rounded corners */
  cornerRadius: number;
  /** Border */
  border?: {
    color: HexColorAlpha;
    width: number;
  };
}

export interface ImageFilters {
  brightness?: number;   // -1..1
  contrast?: number;     // -1..1
  saturation?: number;   // -1..1
  blur?: number;         // 0..50 pixels
  grayscale?: boolean;
  sepia?: boolean;
}

// --- Shape ---

export type ShapeKind = 'rectangle' | 'ellipse' | 'triangle' | 'line' | 'polygon' | 'star';

export interface ShapeElement extends BaseElement {
  type: 'shape';
  shapeKind: ShapeKind;
  fill: Fill;
  stroke?: {
    color: HexColorAlpha;
    width: number;
    dashArray?: number[];
  };
  cornerRadius?: number;
  /** For polygon / star shapes */
  points?: number;
  /** For star shapes: inner radius ratio (0..1) */
  innerRadiusRatio?: number;
}

// --- Photo Zone ---

/**
 * A "photo zone" is a designated rectangular area where the captured photo
 * will be placed at render time. In the exported PNG template, this area
 * becomes transparent (alpha = 0).
 *
 * The iPad renderer composites: background -> photo (in zone) -> overlay layers.
 */
export interface PhotoZoneElement extends BaseElement {
  type: 'photo_zone';
  /** Label shown in the editor (e.g., "Photo 1", "Photo 2") */
  label: string;
  /** Corner radius for rounded photo zones */
  cornerRadius: number;
  /** Border drawn around the zone in the final output */
  border?: {
    color: HexColorAlpha;
    width: number;
  };
  /**
   * For multi-photo templates (e.g., photo strips), this indicates
   * the capture order: which photo goes in this zone.
   */
  captureIndex: number;
  /**
   * Aspect ratio enforcement. If set, resizing maintains this ratio.
   * Format: "width:height" (e.g., "4:3", "16:9")
   */
  aspectRatio?: string;
  /**
   * How the photo fills the zone: 'cover' crops to fill, 'contain' fits inside with letterboxing.
   */
  fillMode: 'cover' | 'contain';
}

// --- Group ---

export interface GroupElement extends BaseElement {
  type: 'group';
  /** IDs of child elements in this group */
  childIds: string[];
}

// ---------------------------------------------------------------------------
// Union Type
// ---------------------------------------------------------------------------

export type TemplateElement =
  | TextElement
  | ImageElement
  | ShapeElement
  | PhotoZoneElement
  | GroupElement;

// ---------------------------------------------------------------------------
// Background
// ---------------------------------------------------------------------------

export interface TemplateBackground {
  type: 'color' | 'gradient' | 'image';
  color?: HexColorAlpha;
  gradient?: GradientFill;
  imageUrl?: string;
  imageAssetId?: string;
}

// ---------------------------------------------------------------------------
// Template Document (Root)
// ---------------------------------------------------------------------------

export interface PhotoBoothTemplate {
  metadata: TemplateMetadata;
  canvas: CanvasSize;
  background: TemplateBackground;
  elements: TemplateElement[];
  /** Font references used by this template (for embedding/preloading) */
  fonts: FontReference[];
  /** Asset manifest: IDs of all assets this template depends on */
  assetIds: string[];
}

// ---------------------------------------------------------------------------
// Video Template Extension
// ---------------------------------------------------------------------------

export interface VideoTemplateConfig {
  /** Total duration in seconds */
  duration: number;
  /** Frame rate */
  fps: number;
  /** Background music */
  audio?: {
    src: string;
    assetId: string;
    volume: number;       // 0..1
    fadeInDuration: number;  // seconds
    fadeOutDuration: number; // seconds
    loop: boolean;
  };
  /** Sound effects */
  soundEffects: Array<{
    src: string;
    assetId: string;
    startTime: number;  // seconds
    volume: number;
    duration: number;
  }>;
  /** Transitions between scenes (if multi-scene) */
  transitions: Array<{
    type: 'fade' | 'slide' | 'wipe' | 'dissolve';
    duration: number;
    fromSceneIndex: number;
    toSceneIndex: number;
  }>;
}

export interface VideoBoothTemplate extends PhotoBoothTemplate {
  video: VideoTemplateConfig;
  /** Scenes (each scene is like a static template with its own elements and timing) */
  scenes: Array<{
    id: string;
    name: string;
    startTime: number;
    duration: number;
    elements: TemplateElement[];
    background: TemplateBackground;
  }>;
}
