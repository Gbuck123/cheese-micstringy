/**
 * FabricCanvas.tsx
 *
 * The core canvas component that wraps fabric.js. Handles:
 *   - Canvas initialization and lifecycle
 *   - Object manipulation events (move, scale, rotate)
 *   - Syncing fabric objects <-> Zustand store
 *   - Keyboard shortcuts (delete, undo/redo, copy/paste)
 *   - Zoom/pan via mouse wheel + middle-mouse drag
 *   - Grid overlay
 *   - Export
 */

import React, { useRef, useEffect, useCallback } from 'react';
import { fabric } from 'fabric';
import { useEditorStore } from '../../hooks/useEditorStore';
import {
  elementToFabricObject,
  fabricObjectToElementUpdates,
  applyBackground,
  exportTemplateToPNG,
} from '../../utils/fabric-helpers';
import type { TemplateElement } from '../../types/template';

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

interface FabricCanvasProps {
  /** Container dimensions (the canvas scales to fit) */
  containerWidth: number;
  containerHeight: number;
  /** Callback after export completes */
  onExport?: (blob: Blob) => void;
  /** Ref handle for imperative export trigger */
  exportRef?: React.MutableRefObject<(() => Promise<Blob>) | null>;
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

const FabricCanvas: React.FC<FabricCanvasProps> = ({
  containerWidth,
  containerHeight,
  onExport,
  exportRef,
}) => {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const fabricRef = useRef<fabric.Canvas | null>(null);
  const isUpdatingFromStore = useRef(false);
  const isUpdatingFromCanvas = useRef(false);

  // --- Store ---
  const {
    elements,
    background,
    canvas: canvasSize,
    selectedIds,
    zoom,
    panX,
    panY,
    showGrid,
    gridSize,
    snapToGrid,
    activeTool,
    select,
    clearSelection,
    updateElement,
    removeElement,
    pushHistory,
    undo,
    redo,
    copy,
    paste,
    cut,
    setZoom,
    setPan,
    fitToScreen,
  } = useEditorStore();

  // ---------------------------------------------------------------------------
  // Canvas Initialization
  // ---------------------------------------------------------------------------

  useEffect(() => {
    if (!canvasRef.current) return;

    const fc = new fabric.Canvas(canvasRef.current, {
      width: containerWidth,
      height: containerHeight,
      backgroundColor: '#f0f0f0',
      preserveObjectStacking: true,
      selection: activeTool === 'select',
      stopContextMenu: true,
      fireRightClick: true,
    });

    fabricRef.current = fc;

    // Configure snapping
    if (snapToGrid) {
      fc.on('object:moving', (e) => {
        const obj = e.target;
        if (!obj || !snapToGrid) return;
        obj.set({
          left: Math.round((obj.left || 0) / gridSize) * gridSize,
          top: Math.round((obj.top || 0) / gridSize) * gridSize,
        });
      });
    }

    // Fit canvas to container on mount
    fitToScreen(containerWidth, containerHeight);

    return () => {
      fc.dispose();
      fabricRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ---------------------------------------------------------------------------
  // Viewport Transform (zoom + pan)
  // ---------------------------------------------------------------------------

  useEffect(() => {
    const fc = fabricRef.current;
    if (!fc) return;
    fc.setViewportTransform([zoom, 0, 0, zoom, panX, panY]);
    fc.renderAll();
  }, [zoom, panX, panY]);

  // ---------------------------------------------------------------------------
  // Sync elements from store -> fabric
  // ---------------------------------------------------------------------------

  useEffect(() => {
    const fc = fabricRef.current;
    if (!fc || isUpdatingFromCanvas.current) return;

    isUpdatingFromStore.current = true;

    // Build a map of existing fabric objects by element ID
    const existingMap = new Map<string, fabric.Object>();
    fc.getObjects().forEach((obj) => {
      if (obj.elementId) {
        existingMap.set(obj.elementId, obj);
      }
    });

    // Track which element IDs are still in the store
    const currentIds = new Set(elements.map((el) => el.id));

    // Remove fabric objects whose elements no longer exist
    existingMap.forEach((obj, id) => {
      if (!currentIds.has(id)) {
        fc.remove(obj);
      }
    });

    // Add or update fabric objects
    const addPromises: Promise<void>[] = [];

    for (const element of elements) {
      const existing = existingMap.get(element.id);
      if (existing) {
        // Update position/size if changed externally (e.g., via properties panel)
        existing.set({
          left: element.x,
          top: element.y,
          angle: element.rotation,
          opacity: element.opacity,
          visible: element.visible,
          selectable: !element.locked,
          evented: !element.locked,
        });

        // For scaled objects, update scaleX/scaleY
        if (existing.width && existing.height) {
          existing.set({
            scaleX: element.width / existing.width,
            scaleY: element.height / existing.height,
          });
        }

        existing.elementData = element;
      } else {
        // Create new fabric object
        addPromises.push(
          elementToFabricObject(element).then((obj) => {
            fc.add(obj);
          }),
        );
      }
    }

    Promise.all(addPromises).then(() => {
      // Sort objects by zIndex
      fc.getObjects().sort((a, b) => {
        const aZ = a.elementData?.zIndex ?? 0;
        const bZ = b.elementData?.zIndex ?? 0;
        return aZ - bZ;
      });
      fc.renderAll();
      isUpdatingFromStore.current = false;
    });

    // Apply background
    applyBackground(fc, background, canvasSize.width, canvasSize.height);
  }, [elements, background, canvasSize]);

  // ---------------------------------------------------------------------------
  // Canvas Event Handlers
  // ---------------------------------------------------------------------------

  useEffect(() => {
    const fc = fabricRef.current;
    if (!fc) return;

    // --- Selection ---
    const handleSelection = () => {
      const active = fc.getActiveObjects();
      const ids = active
        .map((obj) => obj.elementId)
        .filter((id): id is string => !!id);
      select(ids);
    };

    const handleDeselection = () => {
      clearSelection();
    };

    // --- Object Modified (move, scale, rotate) ---
    const handleModified = (e: fabric.IEvent) => {
      if (isUpdatingFromStore.current) return;
      isUpdatingFromCanvas.current = true;

      const obj = e.target;
      if (!obj?.elementId) {
        isUpdatingFromCanvas.current = false;
        return;
      }

      const updates = fabricObjectToElementUpdates(obj);
      updateElement(obj.elementId, updates);
      pushHistory('Move/resize element');

      isUpdatingFromCanvas.current = false;
    };

    fc.on('selection:created', handleSelection);
    fc.on('selection:updated', handleSelection);
    fc.on('selection:cleared', handleDeselection);
    fc.on('object:modified', handleModified);

    return () => {
      fc.off('selection:created', handleSelection);
      fc.off('selection:updated', handleSelection);
      fc.off('selection:cleared', handleDeselection);
      fc.off('object:modified', handleModified);
    };
  }, [select, clearSelection, updateElement, pushHistory]);

  // ---------------------------------------------------------------------------
  // Mouse Wheel Zoom
  // ---------------------------------------------------------------------------

  useEffect(() => {
    const fc = fabricRef.current;
    if (!fc) return;

    const handleWheel = (opt: fabric.IEvent<WheelEvent>) => {
      const e = opt.e;
      e.preventDefault();
      e.stopPropagation();

      const delta = e.deltaY;
      const zoomFactor = 0.999 ** delta;
      const newZoom = Math.max(0.1, Math.min(5, zoom * zoomFactor));

      // Zoom toward mouse pointer
      const pointer = fc.getPointer(e, true);
      const newPanX = pointer.x - (pointer.x - panX) * (newZoom / zoom);
      const newPanY = pointer.y - (pointer.y - panY) * (newZoom / zoom);

      setZoom(newZoom);
      setPan(newPanX, newPanY);
    };

    fc.on('mouse:wheel', handleWheel);
    return () => {
      fc.off('mouse:wheel', handleWheel);
    };
  }, [zoom, panX, panY, setZoom, setPan]);

  // ---------------------------------------------------------------------------
  // Middle-Mouse Pan
  // ---------------------------------------------------------------------------

  useEffect(() => {
    const fc = fabricRef.current;
    if (!fc) return;

    let isPanning = false;
    let lastX = 0;
    let lastY = 0;

    const handleMouseDown = (opt: fabric.IEvent<MouseEvent>) => {
      if (opt.e.button === 1 || activeTool === 'pan') {
        isPanning = true;
        lastX = opt.e.clientX;
        lastY = opt.e.clientY;
        fc.selection = false;
      }
    };

    const handleMouseMove = (opt: fabric.IEvent<MouseEvent>) => {
      if (!isPanning) return;
      const dx = opt.e.clientX - lastX;
      const dy = opt.e.clientY - lastY;
      setPan(panX + dx, panY + dy);
      lastX = opt.e.clientX;
      lastY = opt.e.clientY;
    };

    const handleMouseUp = () => {
      isPanning = false;
      if (activeTool === 'select') {
        fc.selection = true;
      }
    };

    fc.on('mouse:down', handleMouseDown);
    fc.on('mouse:move', handleMouseMove);
    fc.on('mouse:up', handleMouseUp);

    return () => {
      fc.off('mouse:down', handleMouseDown);
      fc.off('mouse:move', handleMouseMove);
      fc.off('mouse:up', handleMouseUp);
    };
  }, [activeTool, panX, panY, setPan]);

  // ---------------------------------------------------------------------------
  // Keyboard Shortcuts
  // ---------------------------------------------------------------------------

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement;
      // Ignore if typing in an input
      if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA') return;

      const mod = e.metaKey || e.ctrlKey;

      if (e.key === 'Delete' || e.key === 'Backspace') {
        selectedIds.forEach((id) => removeElement(id));
      } else if (mod && e.key === 'z' && e.shiftKey) {
        e.preventDefault();
        redo();
      } else if (mod && e.key === 'z') {
        e.preventDefault();
        undo();
      } else if (mod && e.key === 'c') {
        e.preventDefault();
        copy();
      } else if (mod && e.key === 'v') {
        e.preventDefault();
        paste();
      } else if (mod && e.key === 'x') {
        e.preventDefault();
        cut();
      } else if (mod && e.key === 'a') {
        e.preventDefault();
        const fc = fabricRef.current;
        if (fc) {
          const sel = new fabric.ActiveSelection(fc.getObjects(), { canvas: fc });
          fc.setActiveObject(sel);
          fc.renderAll();
        }
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [selectedIds, removeElement, undo, redo, copy, paste, cut]);

  // ---------------------------------------------------------------------------
  // Grid Overlay
  // ---------------------------------------------------------------------------

  useEffect(() => {
    const fc = fabricRef.current;
    if (!fc) return;

    // Remove old grid
    fc.getObjects().forEach((obj) => {
      if ((obj as fabric.Object & { isGrid?: boolean }).isGrid) {
        fc.remove(obj);
      }
    });

    if (!showGrid) {
      fc.renderAll();
      return;
    }

    // Draw grid lines
    const { width, height } = canvasSize;
    for (let x = 0; x <= width; x += gridSize) {
      const line = new fabric.Line([x, 0, x, height], {
        stroke: '#ddd',
        strokeWidth: 0.5,
        selectable: false,
        evented: false,
        excludeFromExport: true,
      });
      (line as fabric.Line & { isGrid: boolean }).isGrid = true;
      fc.add(line);
      fc.sendToBack(line);
    }
    for (let y = 0; y <= height; y += gridSize) {
      const line = new fabric.Line([0, y, width, y], {
        stroke: '#ddd',
        strokeWidth: 0.5,
        selectable: false,
        evented: false,
        excludeFromExport: true,
      });
      (line as fabric.Line & { isGrid: boolean }).isGrid = true;
      fc.add(line);
      fc.sendToBack(line);
    }

    fc.renderAll();
  }, [showGrid, gridSize, canvasSize]);

  // ---------------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------------

  const handleExport = useCallback(async (): Promise<Blob> => {
    const fc = fabricRef.current;
    if (!fc) throw new Error('Canvas not initialized');

    const blob = await exportTemplateToPNG(
      fc,
      elements,
      canvasSize.width,
      canvasSize.height,
    );

    onExport?.(blob);
    return blob;
  }, [elements, canvasSize, onExport]);

  // Expose export via ref
  useEffect(() => {
    if (exportRef) {
      exportRef.current = handleExport;
    }
  }, [exportRef, handleExport]);

  // ---------------------------------------------------------------------------
  // Canvas resize
  // ---------------------------------------------------------------------------

  useEffect(() => {
    const fc = fabricRef.current;
    if (!fc) return;
    fc.setDimensions({
      width: containerWidth,
      height: containerHeight,
    });
    fc.renderAll();
  }, [containerWidth, containerHeight]);

  // ---------------------------------------------------------------------------
  // Render
  // ---------------------------------------------------------------------------

  return (
    <div
      style={{
        width: containerWidth,
        height: containerHeight,
        position: 'relative',
        overflow: 'hidden',
        background: '#e8e8e8',
      }}
    >
      <canvas ref={canvasRef} />
    </div>
  );
};

export default FabricCanvas;
