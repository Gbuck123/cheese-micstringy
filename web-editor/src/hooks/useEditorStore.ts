/**
 * Central editor state management using Zustand + Immer.
 *
 * Features:
 *   - Command-pattern undo/redo (up to 100 states)
 *   - Element CRUD with z-index management
 *   - Selection state
 *   - Canvas zoom/pan
 *   - Clipboard (copy/paste)
 */

import { create } from 'zustand';
import { produce } from 'immer';
import { v4 as uuid } from 'uuid';
import type {
  PhotoBoothTemplate,
  TemplateElement,
  CanvasSize,
  TemplateBackground,
  PresetSize,
  PRESET_SIZES,
  FontReference,
} from '../types/template';

// ---------------------------------------------------------------------------
// Command Pattern for Undo/Redo
// ---------------------------------------------------------------------------

interface HistoryEntry {
  /** Snapshot of elements at this point in time */
  elements: TemplateElement[];
  /** Snapshot of background */
  background: TemplateBackground;
  /** Human-readable description for undo menu */
  label: string;
}

const MAX_HISTORY = 100;

// ---------------------------------------------------------------------------
// Editor State
// ---------------------------------------------------------------------------

export interface EditorState {
  // --- Template data ---
  template: PhotoBoothTemplate | null;
  elements: TemplateElement[];
  background: TemplateBackground;
  canvas: CanvasSize;
  fonts: FontReference[];

  // --- Selection ---
  selectedIds: string[];
  hoveredId: string | null;

  // --- Clipboard ---
  clipboard: TemplateElement[];

  // --- Viewport ---
  zoom: number;
  panX: number;
  panY: number;

  // --- History ---
  history: HistoryEntry[];
  historyIndex: number;

  // --- UI State ---
  activeTool: ActiveTool;
  showGrid: boolean;
  snapToGrid: boolean;
  gridSize: number;

  // --- Actions ---
  initTemplate: (template: PhotoBoothTemplate) => void;
  newTemplate: (canvas: CanvasSize) => void;

  // Element CRUD
  addElement: (element: TemplateElement) => void;
  updateElement: (id: string, updates: Partial<TemplateElement>) => void;
  removeElement: (id: string) => void;
  duplicateElement: (id: string) => void;

  // Selection
  select: (ids: string[]) => void;
  selectAll: () => void;
  clearSelection: () => void;
  setHovered: (id: string | null) => void;

  // Layer management
  bringToFront: (id: string) => void;
  sendToBack: (id: string) => void;
  bringForward: (id: string) => void;
  sendBackward: (id: string) => void;
  toggleLock: (id: string) => void;
  toggleVisibility: (id: string) => void;

  // Background
  setBackground: (bg: TemplateBackground) => void;

  // Canvas
  setCanvasSize: (canvas: CanvasSize) => void;

  // Viewport
  setZoom: (zoom: number) => void;
  setPan: (x: number, y: number) => void;
  fitToScreen: (containerWidth: number, containerHeight: number) => void;

  // History
  undo: () => void;
  redo: () => void;
  pushHistory: (label: string) => void;

  // Clipboard
  copy: () => void;
  paste: () => void;
  cut: () => void;

  // Tools
  setActiveTool: (tool: ActiveTool) => void;
  setShowGrid: (show: boolean) => void;
  setSnapToGrid: (snap: boolean) => void;

  // Font management
  addFont: (font: FontReference) => void;
  removeFont: (family: string) => void;

  // Serialization
  toJSON: () => PhotoBoothTemplate;
}

export type ActiveTool =
  | 'select'
  | 'text'
  | 'shape'
  | 'image'
  | 'photo_zone'
  | 'draw'
  | 'pan';

// ---------------------------------------------------------------------------
// Default Values
// ---------------------------------------------------------------------------

const defaultBackground: TemplateBackground = {
  type: 'color',
  color: '#FFFFFFFF',
};

const defaultCanvas: CanvasSize = {
  preset: '4x6',
  width: 1200,
  height: 1800,
  dpi: 300,
};

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

export const useEditorStore = create<EditorState>((set, get) => ({
  template: null,
  elements: [],
  background: defaultBackground,
  canvas: defaultCanvas,
  fonts: [],
  selectedIds: [],
  hoveredId: null,
  clipboard: [],
  zoom: 1,
  panX: 0,
  panY: 0,
  history: [],
  historyIndex: -1,
  activeTool: 'select',
  showGrid: false,
  snapToGrid: true,
  gridSize: 10,

  // --- Init ---

  initTemplate: (template) => {
    set({
      template,
      elements: template.elements,
      background: template.background,
      canvas: template.canvas,
      fonts: template.fonts,
      selectedIds: [],
      history: [{
        elements: template.elements,
        background: template.background,
        label: 'Load template',
      }],
      historyIndex: 0,
    });
  },

  newTemplate: (canvas) => {
    const now = new Date().toISOString();
    const template: PhotoBoothTemplate = {
      metadata: {
        schemaVersion: 2,
        id: uuid(),
        name: 'Untitled Template',
        createdAt: now,
        updatedAt: now,
        ownerId: '',
        tags: [],
      },
      canvas,
      background: defaultBackground,
      elements: [],
      fonts: [],
      assetIds: [],
    };
    set({
      template,
      elements: [],
      background: defaultBackground,
      canvas,
      fonts: [],
      selectedIds: [],
      history: [{
        elements: [],
        background: defaultBackground,
        label: 'New template',
      }],
      historyIndex: 0,
    });
  },

  // --- Element CRUD ---

  addElement: (element) => {
    set(produce((state: EditorState) => {
      // Assign highest zIndex
      const maxZ = state.elements.reduce((max, el) => Math.max(max, el.zIndex), 0);
      element.zIndex = maxZ + 1;
      state.elements.push(element);
      state.selectedIds = [element.id];
    }));
    get().pushHistory(`Add ${element.type}`);
  },

  updateElement: (id, updates) => {
    set(produce((state: EditorState) => {
      const idx = state.elements.findIndex((el) => el.id === id);
      if (idx !== -1) {
        state.elements[idx] = { ...state.elements[idx], ...updates } as TemplateElement;
      }
    }));
  },

  removeElement: (id) => {
    set(produce((state: EditorState) => {
      state.elements = state.elements.filter((el) => el.id !== id);
      state.selectedIds = state.selectedIds.filter((sid) => sid !== id);
    }));
    get().pushHistory('Delete element');
  },

  duplicateElement: (id) => {
    const state = get();
    const el = state.elements.find((e) => e.id === id);
    if (!el) return;
    const clone: TemplateElement = {
      ...JSON.parse(JSON.stringify(el)),
      id: uuid(),
      name: `${el.name} copy`,
      x: el.x + 20,
      y: el.y + 20,
    };
    get().addElement(clone);
  },

  // --- Selection ---

  select: (ids) => set({ selectedIds: ids }),
  selectAll: () => set((s) => ({ selectedIds: s.elements.map((e) => e.id) })),
  clearSelection: () => set({ selectedIds: [] }),
  setHovered: (id) => set({ hoveredId: id }),

  // --- Layer Management ---

  bringToFront: (id) => {
    set(produce((state: EditorState) => {
      const maxZ = state.elements.reduce((max, el) => Math.max(max, el.zIndex), 0);
      const idx = state.elements.findIndex((el) => el.id === id);
      if (idx !== -1) {
        state.elements[idx].zIndex = maxZ + 1;
      }
    }));
    get().pushHistory('Bring to front');
  },

  sendToBack: (id) => {
    set(produce((state: EditorState) => {
      const minZ = state.elements.reduce((min, el) => Math.min(min, el.zIndex), Infinity);
      const idx = state.elements.findIndex((el) => el.id === id);
      if (idx !== -1) {
        state.elements[idx].zIndex = minZ - 1;
      }
    }));
    get().pushHistory('Send to back');
  },

  bringForward: (id) => {
    set(produce((state: EditorState) => {
      const sorted = [...state.elements].sort((a, b) => a.zIndex - b.zIndex);
      const currentIdx = sorted.findIndex((el) => el.id === id);
      if (currentIdx < sorted.length - 1) {
        const current = sorted[currentIdx];
        const above = sorted[currentIdx + 1];
        // Swap z-indices
        const elIdx = state.elements.findIndex((el) => el.id === current.id);
        const aboveIdx = state.elements.findIndex((el) => el.id === above.id);
        const tempZ = state.elements[elIdx].zIndex;
        state.elements[elIdx].zIndex = state.elements[aboveIdx].zIndex;
        state.elements[aboveIdx].zIndex = tempZ;
      }
    }));
    get().pushHistory('Bring forward');
  },

  sendBackward: (id) => {
    set(produce((state: EditorState) => {
      const sorted = [...state.elements].sort((a, b) => a.zIndex - b.zIndex);
      const currentIdx = sorted.findIndex((el) => el.id === id);
      if (currentIdx > 0) {
        const current = sorted[currentIdx];
        const below = sorted[currentIdx - 1];
        const elIdx = state.elements.findIndex((el) => el.id === current.id);
        const belowIdx = state.elements.findIndex((el) => el.id === below.id);
        const tempZ = state.elements[elIdx].zIndex;
        state.elements[elIdx].zIndex = state.elements[belowIdx].zIndex;
        state.elements[belowIdx].zIndex = tempZ;
      }
    }));
    get().pushHistory('Send backward');
  },

  toggleLock: (id) => {
    set(produce((state: EditorState) => {
      const idx = state.elements.findIndex((el) => el.id === id);
      if (idx !== -1) {
        state.elements[idx].locked = !state.elements[idx].locked;
      }
    }));
  },

  toggleVisibility: (id) => {
    set(produce((state: EditorState) => {
      const idx = state.elements.findIndex((el) => el.id === id);
      if (idx !== -1) {
        state.elements[idx].visible = !state.elements[idx].visible;
      }
    }));
  },

  // --- Background ---

  setBackground: (bg) => {
    set({ background: bg });
    get().pushHistory('Change background');
  },

  // --- Canvas ---

  setCanvasSize: (canvas) => {
    set({ canvas });
    get().pushHistory('Change canvas size');
  },

  // --- Viewport ---

  setZoom: (zoom) => set({ zoom: Math.max(0.1, Math.min(5, zoom)) }),
  setPan: (panX, panY) => set({ panX, panY }),

  fitToScreen: (containerWidth, containerHeight) => {
    const { canvas } = get();
    const padding = 80;
    const scaleX = (containerWidth - padding * 2) / canvas.width;
    const scaleY = (containerHeight - padding * 2) / canvas.height;
    const zoom = Math.min(scaleX, scaleY, 1);
    const panX = (containerWidth - canvas.width * zoom) / 2;
    const panY = (containerHeight - canvas.height * zoom) / 2;
    set({ zoom, panX, panY });
  },

  // --- History (Undo/Redo) ---

  pushHistory: (label) => {
    set(produce((state: EditorState) => {
      // Truncate any redo history beyond current index
      state.history = state.history.slice(0, state.historyIndex + 1);
      state.history.push({
        elements: JSON.parse(JSON.stringify(state.elements)),
        background: JSON.parse(JSON.stringify(state.background)),
        label,
      });
      // Enforce max history size
      if (state.history.length > MAX_HISTORY) {
        state.history = state.history.slice(state.history.length - MAX_HISTORY);
      }
      state.historyIndex = state.history.length - 1;
    }));
  },

  undo: () => {
    const { historyIndex, history } = get();
    if (historyIndex <= 0) return;
    const prev = history[historyIndex - 1];
    set({
      elements: JSON.parse(JSON.stringify(prev.elements)),
      background: JSON.parse(JSON.stringify(prev.background)),
      historyIndex: historyIndex - 1,
      selectedIds: [],
    });
  },

  redo: () => {
    const { historyIndex, history } = get();
    if (historyIndex >= history.length - 1) return;
    const next = history[historyIndex + 1];
    set({
      elements: JSON.parse(JSON.stringify(next.elements)),
      background: JSON.parse(JSON.stringify(next.background)),
      historyIndex: historyIndex + 1,
      selectedIds: [],
    });
  },

  // --- Clipboard ---

  copy: () => {
    const { selectedIds, elements } = get();
    const toCopy = elements.filter((el) => selectedIds.includes(el.id));
    set({ clipboard: JSON.parse(JSON.stringify(toCopy)) });
  },

  paste: () => {
    const { clipboard } = get();
    clipboard.forEach((el) => {
      const clone: TemplateElement = {
        ...JSON.parse(JSON.stringify(el)),
        id: uuid(),
        name: `${el.name} copy`,
        x: el.x + 20,
        y: el.y + 20,
      };
      get().addElement(clone);
    });
  },

  cut: () => {
    get().copy();
    const { selectedIds } = get();
    selectedIds.forEach((id) => get().removeElement(id));
  },

  // --- Tools ---

  setActiveTool: (tool) => set({ activeTool: tool }),
  setShowGrid: (show) => set({ showGrid: show }),
  setSnapToGrid: (snap) => set({ snapToGrid: snap }),

  // --- Fonts ---

  addFont: (font) => {
    set(produce((state: EditorState) => {
      if (!state.fonts.find((f) => f.family === font.family && f.weight === font.weight)) {
        state.fonts.push(font);
      }
    }));
  },

  removeFont: (family) => {
    set(produce((state: EditorState) => {
      state.fonts = state.fonts.filter((f) => f.family !== family);
    }));
  },

  // --- Serialization ---

  toJSON: (): PhotoBoothTemplate => {
    const state = get();
    const now = new Date().toISOString();
    const assetIds = state.elements
      .filter((el): el is Extract<TemplateElement, { type: 'image' }> => el.type === 'image')
      .map((el) => el.assetId);

    return {
      metadata: {
        ...(state.template?.metadata ?? {
          schemaVersion: 2,
          id: uuid(),
          name: 'Untitled Template',
          createdAt: now,
          ownerId: '',
          tags: [],
        }),
        updatedAt: now,
      },
      canvas: state.canvas,
      background: state.background,
      elements: state.elements,
      fonts: state.fonts,
      assetIds: [...new Set(assetIds)],
    };
  },
}));
