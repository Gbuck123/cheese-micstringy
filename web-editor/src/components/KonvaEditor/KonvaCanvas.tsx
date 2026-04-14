/**
 * KonvaCanvas.tsx
 *
 * Alternative canvas-based template editor using react-konva.
 *
 * This provides the same functionality as FabricCanvas but uses
 * Konva.js instead of fabric.js.
 *
 * KEY DIFFERENCES (fabric.js vs Konva):
 *
 * | Aspect              | fabric.js                          | Konva.js (react-konva)            |
 * |---------------------|-------------------------------------|-----------------------------------|
 * | React integration   | Imperative (ref-based)              | Declarative (JSX components)      |
 * | Bundle size         | ~300KB min                          | ~150KB min                        |
 * | Built-in features   | Rich (filters, SVG, serialization)  | Leaner (extensible via plugins)   |
 * | Object model        | Mutable OOP                         | Scene graph (Stage > Layer > Node)|
 * | Text editing        | Built-in inline editing             | Requires custom HTML overlay      |
 * | Performance         | Good; single-canvas                 | Better; multi-layer compositing   |
 * | Serialization       | Built-in toJSON/loadFromJSON        | Manual (toJSON exists but basic)  |
 * | Community           | Larger, older                       | Active, modern                    |
 * | TypeScript          | @types/fabric (decent)              | First-class TypeScript support    |
 * | SSR                 | Possible via node-canvas            | Possible via konva + canvas pkg   |
 *
 * WHEN TO USE WHICH:
 *
 * Use fabric.js when:
 *   - You need rich built-in features (SVG import, complex text, filters)
 *   - You want built-in serialization (toJSON/loadFromJSON)
 *   - Your team is comfortable with imperative canvas manipulation
 *   - You need inline text editing on the canvas
 *
 * Use Konva.js when:
 *   - You want a React-native declarative approach
 *   - You care about bundle size
 *   - You need multi-layer rendering (e.g., static background + interactive foreground)
 *   - You want better TypeScript integration
 *   - You need high-performance rendering with many objects
 *   - You want a simpler API and are willing to build features on top
 *
 * FOR THIS PHOTO BOOTH USE CASE:
 *   Both work well. fabric.js is recommended if you need inline text editing
 *   and complex filter support. Konva.js is recommended if you want cleaner
 *   React code and better performance with many template elements.
 */

import React, { useRef, useEffect, useState, useCallback } from 'react';
import {
  Stage,
  Layer,
  Rect,
  Ellipse,
  Text,
  Image as KonvaImage,
  Transformer,
  Group,
  Line,
  RegularPolygon,
  Star,
} from 'react-konva';
import Konva from 'konva';
import { useEditorStore } from '../../hooks/useEditorStore';
import type {
  TemplateElement,
  TextElement,
  ImageElement,
  ShapeElement,
  PhotoZoneElement,
} from '../../types/template';

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

interface KonvaCanvasProps {
  containerWidth: number;
  containerHeight: number;
  onExport?: (blob: Blob) => void;
  exportRef?: React.MutableRefObject<(() => Promise<Blob>) | null>;
}

// ---------------------------------------------------------------------------
// Custom hook: load an image
// ---------------------------------------------------------------------------

function useLoadImage(src: string | undefined): HTMLImageElement | null {
  const [image, setImage] = useState<HTMLImageElement | null>(null);

  useEffect(() => {
    if (!src) {
      setImage(null);
      return;
    }
    const img = new window.Image();
    img.crossOrigin = 'anonymous';
    img.src = src;
    img.onload = () => setImage(img);
    return () => {
      img.onload = null;
    };
  }, [src]);

  return image;
}

// ---------------------------------------------------------------------------
// Element Renderers
// ---------------------------------------------------------------------------

interface ElementRendererProps {
  element: TemplateElement;
  isSelected: boolean;
  onSelect: () => void;
  onChange: (updates: Partial<TemplateElement>) => void;
}

const TextRenderer: React.FC<ElementRendererProps> = ({
  element,
  isSelected,
  onSelect,
  onChange,
}) => {
  const el = element as TextElement;
  const shapeRef = useRef<Konva.Text>(null);
  const trRef = useRef<Konva.Transformer>(null);

  useEffect(() => {
    if (isSelected && trRef.current && shapeRef.current) {
      trRef.current.nodes([shapeRef.current]);
      trRef.current.getLayer()?.batchDraw();
    }
  }, [isSelected]);

  const fill = typeof el.fill === 'string'
    ? el.fill.length === 9 ? el.fill.slice(0, 7) : el.fill
    : '#000000';

  return (
    <>
      <Text
        ref={shapeRef}
        x={el.x}
        y={el.y}
        width={el.width}
        text={el.content}
        fontFamily={el.font.family}
        fontSize={el.fontSize}
        fontStyle={el.font.style === 'italic' ? 'italic' : 'normal'}
        fill={fill}
        align={el.textAlign}
        lineHeight={el.lineHeight}
        letterSpacing={el.letterSpacing}
        rotation={el.rotation}
        opacity={el.opacity}
        visible={el.visible}
        draggable={!el.locked}
        onClick={onSelect}
        onTap={onSelect}
        onDragEnd={(e) => {
          onChange({ x: e.target.x(), y: e.target.y() });
        }}
        onTransformEnd={() => {
          const node = shapeRef.current;
          if (!node) return;
          const scaleX = node.scaleX();
          const scaleY = node.scaleY();
          node.scaleX(1);
          node.scaleY(1);
          onChange({
            x: node.x(),
            y: node.y(),
            width: Math.max(5, node.width() * scaleX),
            height: Math.max(5, node.height() * scaleY),
            rotation: node.rotation(),
          });
        }}
      />
      {isSelected && (
        <Transformer
          ref={trRef}
          flipEnabled={false}
          boundBoxFunc={(oldBox, newBox) => {
            if (Math.abs(newBox.width) < 5 || Math.abs(newBox.height) < 5) {
              return oldBox;
            }
            return newBox;
          }}
        />
      )}
    </>
  );
};

const ImageRenderer: React.FC<ElementRendererProps> = ({
  element,
  isSelected,
  onSelect,
  onChange,
}) => {
  const el = element as ImageElement;
  const image = useLoadImage(el.src);
  const shapeRef = useRef<Konva.Image>(null);
  const trRef = useRef<Konva.Transformer>(null);

  useEffect(() => {
    if (isSelected && trRef.current && shapeRef.current) {
      trRef.current.nodes([shapeRef.current]);
      trRef.current.getLayer()?.batchDraw();
    }
  }, [isSelected]);

  if (!image) return null;

  return (
    <>
      <KonvaImage
        ref={shapeRef}
        image={image}
        x={el.x}
        y={el.y}
        width={el.width}
        height={el.height}
        rotation={el.rotation}
        opacity={el.opacity}
        visible={el.visible}
        draggable={!el.locked}
        cornerRadius={el.cornerRadius}
        onClick={onSelect}
        onTap={onSelect}
        onDragEnd={(e) => {
          onChange({ x: e.target.x(), y: e.target.y() });
        }}
        onTransformEnd={() => {
          const node = shapeRef.current;
          if (!node) return;
          const scaleX = node.scaleX();
          const scaleY = node.scaleY();
          node.scaleX(1);
          node.scaleY(1);
          onChange({
            x: node.x(),
            y: node.y(),
            width: Math.max(5, node.width() * scaleX),
            height: Math.max(5, node.height() * scaleY),
            rotation: node.rotation(),
          });
        }}
      />
      {isSelected && (
        <Transformer
          ref={trRef}
          flipEnabled={false}
        />
      )}
    </>
  );
};

const ShapeRenderer: React.FC<ElementRendererProps> = ({
  element,
  isSelected,
  onSelect,
  onChange,
}) => {
  const el = element as ShapeElement;
  const shapeRef = useRef<Konva.Shape>(null);
  const trRef = useRef<Konva.Transformer>(null);

  useEffect(() => {
    if (isSelected && trRef.current && shapeRef.current) {
      trRef.current.nodes([shapeRef.current]);
      trRef.current.getLayer()?.batchDraw();
    }
  }, [isSelected]);

  const fill = typeof el.fill === 'string'
    ? el.fill.length === 9 ? el.fill.slice(0, 7) : el.fill
    : '#4A90D9';

  const commonProps = {
    x: el.x,
    y: el.y,
    rotation: el.rotation,
    opacity: el.opacity,
    visible: el.visible,
    draggable: !el.locked,
    fill,
    stroke: el.stroke?.color?.slice(0, 7),
    strokeWidth: el.stroke?.width ?? 0,
    onClick: onSelect,
    onTap: onSelect,
    onDragEnd: (e: Konva.KonvaEventObject<DragEvent>) => {
      onChange({ x: e.target.x(), y: e.target.y() });
    },
    onTransformEnd: () => {
      const node = shapeRef.current;
      if (!node) return;
      const scaleX = node.scaleX();
      const scaleY = node.scaleY();
      node.scaleX(1);
      node.scaleY(1);
      onChange({
        x: node.x(),
        y: node.y(),
        width: Math.max(5, node.width() * scaleX),
        height: Math.max(5, node.height() * scaleY),
        rotation: node.rotation(),
      });
    },
  };

  let shapeNode: React.ReactNode;

  switch (el.shapeKind) {
    case 'rectangle':
      shapeNode = (
        <Rect
          ref={shapeRef as React.RefObject<Konva.Rect>}
          {...commonProps}
          width={el.width}
          height={el.height}
          cornerRadius={el.cornerRadius ?? 0}
        />
      );
      break;

    case 'ellipse':
      shapeNode = (
        <Ellipse
          ref={shapeRef as React.RefObject<Konva.Ellipse>}
          {...commonProps}
          radiusX={el.width / 2}
          radiusY={el.height / 2}
        />
      );
      break;

    case 'triangle':
      shapeNode = (
        <RegularPolygon
          ref={shapeRef as React.RefObject<Konva.RegularPolygon>}
          {...commonProps}
          sides={3}
          radius={Math.min(el.width, el.height) / 2}
        />
      );
      break;

    case 'polygon':
      shapeNode = (
        <RegularPolygon
          ref={shapeRef as React.RefObject<Konva.RegularPolygon>}
          {...commonProps}
          sides={el.points ?? 6}
          radius={Math.min(el.width, el.height) / 2}
        />
      );
      break;

    case 'star':
      shapeNode = (
        <Star
          ref={shapeRef as React.RefObject<Konva.Star>}
          {...commonProps}
          numPoints={el.points ?? 5}
          outerRadius={Math.min(el.width, el.height) / 2}
          innerRadius={Math.min(el.width, el.height) / 2 * (el.innerRadiusRatio ?? 0.4)}
        />
      );
      break;

    case 'line':
      shapeNode = (
        <Line
          ref={shapeRef as React.RefObject<Konva.Line>}
          {...commonProps}
          points={[0, 0, el.width, el.height]}
          stroke={fill}
          strokeWidth={el.stroke?.width ?? 2}
          fill={undefined}
        />
      );
      break;

    default:
      shapeNode = (
        <Rect
          ref={shapeRef as React.RefObject<Konva.Rect>}
          {...commonProps}
          width={el.width}
          height={el.height}
        />
      );
  }

  return (
    <>
      {shapeNode}
      {isSelected && (
        <Transformer
          ref={trRef}
          flipEnabled={false}
        />
      )}
    </>
  );
};

const PhotoZoneRenderer: React.FC<ElementRendererProps> = ({
  element,
  isSelected,
  onSelect,
  onChange,
}) => {
  const el = element as PhotoZoneElement;
  const groupRef = useRef<Konva.Group>(null);
  const trRef = useRef<Konva.Transformer>(null);

  useEffect(() => {
    if (isSelected && trRef.current && groupRef.current) {
      trRef.current.nodes([groupRef.current]);
      trRef.current.getLayer()?.batchDraw();
    }
  }, [isSelected]);

  return (
    <>
      <Group
        ref={groupRef}
        x={el.x}
        y={el.y}
        rotation={el.rotation}
        opacity={el.opacity}
        visible={el.visible}
        draggable={!el.locked}
        onClick={onSelect}
        onTap={onSelect}
        onDragEnd={(e) => {
          onChange({ x: e.target.x(), y: e.target.y() });
        }}
        onTransformEnd={() => {
          const node = groupRef.current;
          if (!node) return;
          const scaleX = node.scaleX();
          const scaleY = node.scaleY();
          node.scaleX(1);
          node.scaleY(1);
          onChange({
            x: node.x(),
            y: node.y(),
            width: Math.max(5, el.width * scaleX),
            height: Math.max(5, el.height * scaleY),
            rotation: node.rotation(),
          });
        }}
      >
        {/* Zone background */}
        <Rect
          width={el.width}
          height={el.height}
          fill="rgba(100, 149, 237, 0.2)"
          stroke="#6495ED"
          strokeWidth={2}
          dash={[8, 4]}
          cornerRadius={el.cornerRadius}
        />

        {/* Zone label */}
        <Text
          text={el.label || `Photo ${el.captureIndex + 1}`}
          fontSize={Math.min(el.width, el.height) * 0.08}
          fill="#6495ED"
          width={el.width}
          height={el.height}
          align="center"
          verticalAlign="middle"
        />
      </Group>
      {isSelected && (
        <Transformer
          ref={trRef}
          flipEnabled={false}
        />
      )}
    </>
  );
};

// ---------------------------------------------------------------------------
// Element dispatcher
// ---------------------------------------------------------------------------

const ElementNode: React.FC<ElementRendererProps> = (props) => {
  switch (props.element.type) {
    case 'text':
      return <TextRenderer {...props} />;
    case 'image':
      return <ImageRenderer {...props} />;
    case 'shape':
      return <ShapeRenderer {...props} />;
    case 'photo_zone':
      return <PhotoZoneRenderer {...props} />;
    default:
      return null;
  }
};

// ---------------------------------------------------------------------------
// Main KonvaCanvas component
// ---------------------------------------------------------------------------

const KonvaCanvas: React.FC<KonvaCanvasProps> = ({
  containerWidth,
  containerHeight,
  onExport,
  exportRef,
}) => {
  const stageRef = useRef<Konva.Stage>(null);

  const {
    elements,
    background,
    canvas: canvasSize,
    selectedIds,
    zoom,
    panX,
    panY,
    select,
    clearSelection,
    updateElement,
    pushHistory,
    setZoom,
    setPan,
  } = useEditorStore();

  // Sort elements by zIndex
  const sortedElements = [...elements].sort((a, b) => a.zIndex - b.zIndex);

  // Background color
  const bgColor =
    background.type === 'color' && background.color
      ? background.color.slice(0, 7)
      : '#FFFFFF';

  // Click on empty space -> deselect
  const handleStageClick = (e: Konva.KonvaEventObject<MouseEvent>) => {
    if (e.target === e.target.getStage()) {
      clearSelection();
    }
  };

  // Mouse wheel zoom
  const handleWheel = (e: Konva.KonvaEventObject<WheelEvent>) => {
    e.evt.preventDefault();
    const stage = stageRef.current;
    if (!stage) return;

    const scaleBy = 1.05;
    const oldScale = stage.scaleX();
    const pointer = stage.getPointerPosition();
    if (!pointer) return;

    const mousePointTo = {
      x: (pointer.x - stage.x()) / oldScale,
      y: (pointer.y - stage.y()) / oldScale,
    };

    const direction = e.evt.deltaY > 0 ? -1 : 1;
    const newScale = direction > 0 ? oldScale * scaleBy : oldScale / scaleBy;
    const clampedScale = Math.max(0.1, Math.min(5, newScale));

    setZoom(clampedScale);
    setPan(
      pointer.x - mousePointTo.x * clampedScale,
      pointer.y - mousePointTo.y * clampedScale,
    );
  };

  // Export
  const handleExport = useCallback(async (): Promise<Blob> => {
    const stage = stageRef.current;
    if (!stage) throw new Error('Stage not ready');

    // Export at full resolution
    const dataUrl = stage.toDataURL({
      pixelRatio: canvasSize.width / (containerWidth * zoom),
      mimeType: 'image/png',
    });

    // Convert data URL to Blob
    const res = await fetch(dataUrl);
    const blob = await res.blob();

    // TODO: punch out photo zones (similar to fabric approach)
    // For now, return the full render
    onExport?.(blob);
    return blob;
  }, [canvasSize, containerWidth, zoom, onExport]);

  useEffect(() => {
    if (exportRef) {
      exportRef.current = handleExport;
    }
  }, [exportRef, handleExport]);

  return (
    <div
      style={{
        width: containerWidth,
        height: containerHeight,
        background: '#e8e8e8',
        overflow: 'hidden',
      }}
    >
      <Stage
        ref={stageRef}
        width={containerWidth}
        height={containerHeight}
        scaleX={zoom}
        scaleY={zoom}
        x={panX}
        y={panY}
        onClick={handleStageClick}
        onWheel={handleWheel}
        draggable={false}
      >
        {/* Background layer (non-interactive) */}
        <Layer listening={false}>
          <Rect
            x={0}
            y={0}
            width={canvasSize.width}
            height={canvasSize.height}
            fill={bgColor}
          />
        </Layer>

        {/* Elements layer */}
        <Layer>
          {sortedElements.map((element) => (
            <ElementNode
              key={element.id}
              element={element}
              isSelected={selectedIds.includes(element.id)}
              onSelect={() => select([element.id])}
              onChange={(updates) => {
                updateElement(element.id, updates);
                pushHistory('Transform');
              }}
            />
          ))}
        </Layer>
      </Stage>
    </div>
  );
};

export default KonvaCanvas;
