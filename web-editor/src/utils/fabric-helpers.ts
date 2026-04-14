/**
 * Fabric.js helper utilities for converting between our TemplateElement types
 * and fabric.js objects, plus export functionality.
 */

import { fabric } from 'fabric';
import { v4 as uuid } from 'uuid';
import type {
  TemplateElement,
  TextElement,
  ImageElement,
  ShapeElement,
  PhotoZoneElement,
  TemplateBackground,
  Fill,
  GradientFill,
  FontReference,
} from '../types/template';

// ---------------------------------------------------------------------------
// Custom data attached to every fabric object so we can round-trip
// ---------------------------------------------------------------------------

declare module 'fabric' {
  namespace fabric {
    interface Object {
      /** Our element ID */
      elementId?: string;
      /** Our element type */
      elementType?: string;
      /** Full element data for serialization */
      elementData?: TemplateElement;
    }
  }
}

// ---------------------------------------------------------------------------
// Color helpers
// ---------------------------------------------------------------------------

function hexToRgba(hex: string): string {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  const a = hex.length === 9 ? parseInt(hex.slice(7, 9), 16) / 255 : 1;
  return `rgba(${r}, ${g}, ${b}, ${a})`;
}

function resolveFill(fill: Fill): string | fabric.Gradient {
  if (typeof fill === 'string') {
    return hexToRgba(fill);
  }
  // Gradient
  const gf = fill as GradientFill;
  const colorStops: Record<string, string> = {};
  gf.stops.forEach((stop) => {
    colorStops[String(stop.offset)] = hexToRgba(stop.color);
  });

  if (gf.type === 'linear') {
    const angleRad = ((gf.angle ?? 0) * Math.PI) / 180;
    return new fabric.Gradient({
      type: 'linear',
      coords: {
        x1: 0,
        y1: 0,
        x2: Math.cos(angleRad) * 100,
        y2: Math.sin(angleRad) * 100,
      },
      colorStops: gf.stops.map((s) => ({
        offset: s.offset,
        color: hexToRgba(s.color),
      })),
    });
  }

  return new fabric.Gradient({
    type: 'radial',
    coords: { x1: 50, y1: 50, r1: 0, x2: 50, y2: 50, r2: 50 },
    colorStops: gf.stops.map((s) => ({
      offset: s.offset,
      color: hexToRgba(s.color),
    })),
  });
}

// ---------------------------------------------------------------------------
// Element -> Fabric Object
// ---------------------------------------------------------------------------

export function elementToFabricObject(
  element: TemplateElement,
): Promise<fabric.Object> {
  switch (element.type) {
    case 'text':
      return Promise.resolve(createTextObject(element));
    case 'image':
      return createImageObject(element);
    case 'shape':
      return Promise.resolve(createShapeObject(element));
    case 'photo_zone':
      return Promise.resolve(createPhotoZoneObject(element));
    default:
      return Promise.resolve(new fabric.Rect());
  }
}

function applyBaseProps(obj: fabric.Object, el: TemplateElement): void {
  obj.set({
    left: el.x,
    top: el.y,
    width: el.width,
    height: el.height,
    angle: el.rotation,
    opacity: el.opacity,
    selectable: !el.locked,
    evented: !el.locked,
    visible: el.visible,
    lockMovementX: el.locked,
    lockMovementY: el.locked,
    lockScalingX: el.locked,
    lockScalingY: el.locked,
    lockRotation: el.locked,
  });
  obj.elementId = el.id;
  obj.elementType = el.type;
  obj.elementData = el;

  if (el.shadow) {
    obj.set('shadow', new fabric.Shadow({
      color: hexToRgba(el.shadow.color),
      blur: el.shadow.blur,
      offsetX: el.shadow.offsetX,
      offsetY: el.shadow.offsetY,
    }));
  }
}

function createTextObject(el: TextElement): fabric.Textbox {
  const text = new fabric.Textbox(el.content, {
    left: el.x,
    top: el.y,
    width: el.width,
    fontFamily: el.font.family,
    fontSize: el.fontSize,
    fill: typeof el.fill === 'string' ? hexToRgba(el.fill) : undefined,
    textAlign: el.textAlign,
    lineHeight: el.lineHeight,
    charSpacing: el.letterSpacing * 10, // fabric uses 1/1000 em
    underline: el.textDecoration === 'underline',
    linethrough: el.textDecoration === 'line-through',
    fontWeight: el.font.weight as unknown as string,
    fontStyle: el.font.style,
  });

  if (el.stroke) {
    text.set({
      stroke: hexToRgba(el.stroke.color),
      strokeWidth: el.stroke.width,
    });
  }

  applyBaseProps(text, el);
  return text;
}

function createImageObject(el: ImageElement): Promise<fabric.Image> {
  return new Promise((resolve) => {
    fabric.Image.fromURL(
      el.src,
      (img) => {
        img.set({
          left: el.x,
          top: el.y,
          scaleX: el.width / (img.width || el.width),
          scaleY: el.height / (img.height || el.height),
        });

        if (el.cornerRadius > 0) {
          img.set('clipPath', new fabric.Rect({
            width: el.width,
            height: el.height,
            rx: el.cornerRadius,
            ry: el.cornerRadius,
            originX: 'center',
            originY: 'center',
          }));
        }

        applyBaseProps(img, el);
        resolve(img);
      },
      { crossOrigin: 'anonymous' },
    );
  });
}

function createShapeObject(el: ShapeElement): fabric.Object {
  let shape: fabric.Object;

  switch (el.shapeKind) {
    case 'rectangle':
      shape = new fabric.Rect({
        width: el.width,
        height: el.height,
        rx: el.cornerRadius || 0,
        ry: el.cornerRadius || 0,
        fill: resolveFill(el.fill) as string,
      });
      break;

    case 'ellipse':
      shape = new fabric.Ellipse({
        rx: el.width / 2,
        ry: el.height / 2,
        fill: resolveFill(el.fill) as string,
      });
      break;

    case 'triangle':
      shape = new fabric.Triangle({
        width: el.width,
        height: el.height,
        fill: resolveFill(el.fill) as string,
      });
      break;

    case 'line':
      shape = new fabric.Line([0, 0, el.width, el.height], {
        stroke: typeof el.fill === 'string' ? hexToRgba(el.fill) : '#000000',
        strokeWidth: el.stroke?.width || 2,
      });
      break;

    case 'polygon': {
      const points = el.points || 6;
      const polyPoints = generatePolygonPoints(points, Math.min(el.width, el.height) / 2);
      shape = new fabric.Polygon(polyPoints, {
        fill: resolveFill(el.fill) as string,
      });
      break;
    }

    case 'star': {
      const starPoints = el.points || 5;
      const outerRadius = Math.min(el.width, el.height) / 2;
      const innerRadius = outerRadius * (el.innerRadiusRatio || 0.4);
      const pts = generateStarPoints(starPoints, outerRadius, innerRadius);
      shape = new fabric.Polygon(pts, {
        fill: resolveFill(el.fill) as string,
      });
      break;
    }

    default:
      shape = new fabric.Rect({
        width: el.width,
        height: el.height,
        fill: resolveFill(el.fill) as string,
      });
  }

  if (el.stroke) {
    shape.set({
      stroke: hexToRgba(el.stroke.color),
      strokeWidth: el.stroke.width,
      strokeDashArray: el.stroke.dashArray,
    });
  }

  applyBaseProps(shape, el);
  return shape;
}

/**
 * Photo Zone: rendered as a dashed-border rectangle with a semi-transparent
 * fill in the editor. During export, this area becomes fully transparent.
 */
function createPhotoZoneObject(el: PhotoZoneElement): fabric.Group {
  const rect = new fabric.Rect({
    width: el.width,
    height: el.height,
    fill: 'rgba(100, 149, 237, 0.2)', // Cornflower blue, semi-transparent
    stroke: '#6495ED',
    strokeWidth: 2,
    strokeDashArray: [8, 4],
    rx: el.cornerRadius,
    ry: el.cornerRadius,
  });

  const label = new fabric.Text(el.label || `Photo ${el.captureIndex + 1}`, {
    fontSize: Math.min(el.width, el.height) * 0.08,
    fill: '#6495ED',
    fontFamily: 'system-ui, sans-serif',
    textAlign: 'center',
    originX: 'center',
    originY: 'center',
    left: el.width / 2,
    top: el.height / 2,
  });

  // Camera icon (simple text representation)
  const icon = new fabric.Text('\u{1F4F7}', {
    fontSize: Math.min(el.width, el.height) * 0.15,
    originX: 'center',
    originY: 'center',
    left: el.width / 2,
    top: el.height / 2 - Math.min(el.width, el.height) * 0.1,
  });

  const group = new fabric.Group([rect, icon, label], {
    left: el.x,
    top: el.y,
    width: el.width,
    height: el.height,
  });

  applyBaseProps(group, el);
  return group;
}

// ---------------------------------------------------------------------------
// Fabric Object -> TemplateElement (reverse sync)
// ---------------------------------------------------------------------------

export function fabricObjectToElementUpdates(
  obj: fabric.Object,
): Partial<TemplateElement> {
  const scaleX = obj.scaleX || 1;
  const scaleY = obj.scaleY || 1;
  return {
    x: obj.left || 0,
    y: obj.top || 0,
    width: (obj.width || 0) * scaleX,
    height: (obj.height || 0) * scaleY,
    rotation: obj.angle || 0,
    opacity: obj.opacity ?? 1,
  } as Partial<TemplateElement>;
}

// ---------------------------------------------------------------------------
// Export: Render template to PNG with transparent photo zones
// ---------------------------------------------------------------------------

export async function exportTemplateToPNG(
  canvas: fabric.Canvas,
  elements: TemplateElement[],
  canvasWidth: number,
  canvasHeight: number,
): Promise<Blob> {
  // 1. Clone the canvas into an offscreen canvas at full resolution
  const exportCanvas = document.createElement('canvas');
  exportCanvas.width = canvasWidth;
  exportCanvas.height = canvasHeight;
  const ctx = exportCanvas.getContext('2d')!;

  // 2. Draw the fabric canvas at full resolution
  // Reset zoom/pan so we export at 1:1
  const origViewport = canvas.viewportTransform?.slice() || [1, 0, 0, 1, 0, 0];
  canvas.setViewportTransform([1, 0, 0, 1, 0, 0]);
  canvas.renderAll();

  // Get data URL and draw to our export canvas
  const dataUrl = canvas.toDataURL({
    format: 'png',
    multiplier: 1,
    width: canvasWidth,
    height: canvasHeight,
  });

  const img = await loadImage(dataUrl);
  ctx.drawImage(img, 0, 0);

  // 3. Punch out photo zones (make them transparent)
  const photoZones = elements.filter(
    (el): el is PhotoZoneElement => el.type === 'photo_zone',
  );

  ctx.globalCompositeOperation = 'destination-out';
  for (const zone of photoZones) {
    ctx.save();
    ctx.translate(zone.x + zone.width / 2, zone.y + zone.height / 2);
    ctx.rotate((zone.rotation * Math.PI) / 180);

    if (zone.cornerRadius > 0) {
      roundedRect(
        ctx,
        -zone.width / 2,
        -zone.height / 2,
        zone.width,
        zone.height,
        zone.cornerRadius,
      );
    } else {
      ctx.fillRect(-zone.width / 2, -zone.height / 2, zone.width, zone.height);
    }
    ctx.restore();
  }

  // Restore viewport
  canvas.setViewportTransform(origViewport as [number, number, number, number, number, number]);
  canvas.renderAll();

  // 4. Convert to Blob
  return new Promise((resolve) => {
    exportCanvas.toBlob((blob) => {
      resolve(blob!);
    }, 'image/png');
  });
}

// ---------------------------------------------------------------------------
// Background helpers
// ---------------------------------------------------------------------------

export function applyBackground(
  canvas: fabric.Canvas,
  bg: TemplateBackground,
  width: number,
  height: number,
): void {
  switch (bg.type) {
    case 'color':
      canvas.setBackgroundColor(
        bg.color ? hexToRgba(bg.color) : 'white',
        () => canvas.renderAll(),
      );
      break;

    case 'gradient':
      if (bg.gradient) {
        const grad = new fabric.Gradient({
          type: bg.gradient.type,
          coords:
            bg.gradient.type === 'linear'
              ? { x1: 0, y1: 0, x2: width, y2: height }
              : { x1: width / 2, y1: height / 2, r1: 0, x2: width / 2, y2: height / 2, r2: Math.max(width, height) / 2 },
          colorStops: bg.gradient.stops.map((s) => ({
            offset: s.offset,
            color: hexToRgba(s.color),
          })),
        });
        canvas.setBackgroundColor(grad as unknown as string, () => canvas.renderAll());
      }
      break;

    case 'image':
      if (bg.imageUrl) {
        fabric.Image.fromURL(
          bg.imageUrl,
          (img) => {
            img.scaleToWidth(width);
            img.scaleToHeight(height);
            canvas.setBackgroundImage(img, () => canvas.renderAll());
          },
          { crossOrigin: 'anonymous' },
        );
      }
      break;
  }
}

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

function generatePolygonPoints(
  sides: number,
  radius: number,
): fabric.Point[] {
  const points: fabric.Point[] = [];
  const step = (Math.PI * 2) / sides;
  for (let i = 0; i < sides; i++) {
    const angle = i * step - Math.PI / 2;
    points.push(
      new fabric.Point(
        radius + radius * Math.cos(angle),
        radius + radius * Math.sin(angle),
      ),
    );
  }
  return points;
}

function generateStarPoints(
  points: number,
  outerRadius: number,
  innerRadius: number,
): fabric.Point[] {
  const pts: fabric.Point[] = [];
  const step = Math.PI / points;
  for (let i = 0; i < points * 2; i++) {
    const r = i % 2 === 0 ? outerRadius : innerRadius;
    const angle = i * step - Math.PI / 2;
    pts.push(
      new fabric.Point(
        outerRadius + r * Math.cos(angle),
        outerRadius + r * Math.sin(angle),
      ),
    );
  }
  return pts;
}

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.src = src;
  });
}

function roundedRect(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  r: number,
): void {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.lineTo(x + w - r, y);
  ctx.quadraticCurveTo(x + w, y, x + w, y + r);
  ctx.lineTo(x + w, y + h - r);
  ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  ctx.lineTo(x + r, y + h);
  ctx.quadraticCurveTo(x, y + h, x, y + h - r);
  ctx.lineTo(x, y + r);
  ctx.quadraticCurveTo(x, y, x + r, y);
  ctx.closePath();
  ctx.fill();
}

// ---------------------------------------------------------------------------
// Create default elements (factory functions)
// ---------------------------------------------------------------------------

export function createDefaultTextElement(
  overrides?: Partial<TextElement>,
): TextElement {
  return {
    id: uuid(),
    type: 'text',
    name: 'Text',
    x: 100,
    y: 100,
    width: 300,
    height: 60,
    rotation: 0,
    opacity: 1,
    zIndex: 0,
    locked: false,
    visible: true,
    blendMode: 'normal',
    content: 'Your text here',
    font: {
      family: 'Inter',
      weight: 400,
      style: 'normal',
      urls: {},
    },
    fontSize: 32,
    fill: '#000000FF',
    textAlign: 'left',
    verticalAlign: 'top',
    lineHeight: 1.2,
    letterSpacing: 0,
    textDecoration: 'none',
    textTransform: 'none',
    ...overrides,
  };
}

export function createDefaultPhotoZone(
  captureIndex: number,
  overrides?: Partial<PhotoZoneElement>,
): PhotoZoneElement {
  return {
    id: uuid(),
    type: 'photo_zone',
    name: `Photo Zone ${captureIndex + 1}`,
    x: 50,
    y: 50,
    width: 400,
    height: 300,
    rotation: 0,
    opacity: 1,
    zIndex: 0,
    locked: false,
    visible: true,
    blendMode: 'normal',
    label: `Photo ${captureIndex + 1}`,
    cornerRadius: 0,
    captureIndex,
    fillMode: 'cover',
    ...overrides,
  };
}

export function createDefaultShape(
  overrides?: Partial<ShapeElement>,
): ShapeElement {
  return {
    id: uuid(),
    type: 'shape',
    name: 'Shape',
    x: 100,
    y: 100,
    width: 200,
    height: 200,
    rotation: 0,
    opacity: 1,
    zIndex: 0,
    locked: false,
    visible: true,
    blendMode: 'normal',
    shapeKind: 'rectangle',
    fill: '#4A90D9FF',
    ...overrides,
  };
}

export function createDefaultImageElement(
  src: string,
  assetId: string,
  width: number,
  height: number,
): ImageElement {
  return {
    id: uuid(),
    type: 'image',
    name: 'Image',
    x: 50,
    y: 50,
    width,
    height,
    rotation: 0,
    opacity: 1,
    zIndex: 0,
    locked: false,
    visible: true,
    blendMode: 'normal',
    src,
    assetId,
    cornerRadius: 0,
  };
}
