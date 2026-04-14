/**
 * Toolbar.tsx
 *
 * Top toolbar for the template editor. Provides:
 *   - Tool selection (select, text, shape, image, photo zone, draw, pan)
 *   - Undo/Redo buttons
 *   - Zoom controls
 *   - Canvas size preset selector
 *   - Export button
 *   - Grid toggle
 */

import React from 'react';
import { v4 as uuid } from 'uuid';
import { useEditorStore, ActiveTool } from '../../hooks/useEditorStore';
import {
  createDefaultTextElement,
  createDefaultPhotoZone,
  createDefaultShape,
} from '../../utils/fabric-helpers';
import { PRESET_SIZES, PresetSize, CanvasSize } from '../../types/template';

interface ToolbarProps {
  onExport: () => void;
  onImportImage: () => void;
  onSave: () => void;
}

const TOOLS: { id: ActiveTool; label: string; icon: string }[] = [
  { id: 'select', label: 'Select', icon: '↖' },
  { id: 'text', label: 'Text', icon: 'T' },
  { id: 'shape', label: 'Shape', icon: '◻' },
  { id: 'image', label: 'Image', icon: '🖼' },
  { id: 'photo_zone', label: 'Photo Zone', icon: '📷' },
  { id: 'draw', label: 'Draw', icon: '✏' },
  { id: 'pan', label: 'Pan', icon: '✋' },
];

const Toolbar: React.FC<ToolbarProps> = ({ onExport, onImportImage, onSave }) => {
  const {
    activeTool,
    setActiveTool,
    undo,
    redo,
    zoom,
    setZoom,
    historyIndex,
    history,
    canvas,
    setCanvasSize,
    showGrid,
    setShowGrid,
    snapToGrid,
    setSnapToGrid,
    addElement,
    elements,
  } = useEditorStore();

  const canUndo = historyIndex > 0;
  const canRedo = historyIndex < history.length - 1;

  const handleToolClick = (tool: ActiveTool) => {
    setActiveTool(tool);

    // For creation tools, immediately add a default element
    switch (tool) {
      case 'text':
        addElement(createDefaultTextElement());
        setActiveTool('select');
        break;
      case 'shape':
        addElement(createDefaultShape());
        setActiveTool('select');
        break;
      case 'photo_zone': {
        const existingZones = elements.filter((el) => el.type === 'photo_zone');
        addElement(createDefaultPhotoZone(existingZones.length));
        setActiveTool('select');
        break;
      }
      case 'image':
        onImportImage();
        setActiveTool('select');
        break;
    }
  };

  const handlePresetChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    const preset = e.target.value as PresetSize;
    if (preset === 'custom') {
      // Keep current dimensions
      setCanvasSize({ ...canvas, preset: 'custom' });
    } else {
      setCanvasSize(PRESET_SIZES[preset]);
    }
  };

  return (
    <div style={styles.toolbar}>
      {/* Tool buttons */}
      <div style={styles.toolGroup}>
        {TOOLS.map((tool) => (
          <button
            key={tool.id}
            onClick={() => handleToolClick(tool.id)}
            style={{
              ...styles.toolButton,
              ...(activeTool === tool.id ? styles.toolButtonActive : {}),
            }}
            title={tool.label}
          >
            <span style={styles.toolIcon}>{tool.icon}</span>
            <span style={styles.toolLabel}>{tool.label}</span>
          </button>
        ))}
      </div>

      <div style={styles.separator} />

      {/* Undo/Redo */}
      <div style={styles.toolGroup}>
        <button
          onClick={undo}
          disabled={!canUndo}
          style={{
            ...styles.iconButton,
            opacity: canUndo ? 1 : 0.4,
          }}
          title="Undo (Ctrl+Z)"
        >
          ↩
        </button>
        <button
          onClick={redo}
          disabled={!canRedo}
          style={{
            ...styles.iconButton,
            opacity: canRedo ? 1 : 0.4,
          }}
          title="Redo (Ctrl+Shift+Z)"
        >
          ↪
        </button>
      </div>

      <div style={styles.separator} />

      {/* Zoom */}
      <div style={styles.toolGroup}>
        <button
          onClick={() => setZoom(zoom - 0.1)}
          style={styles.iconButton}
          title="Zoom out"
        >
          -
        </button>
        <span style={styles.zoomLabel}>{Math.round(zoom * 100)}%</span>
        <button
          onClick={() => setZoom(zoom + 0.1)}
          style={styles.iconButton}
          title="Zoom in"
        >
          +
        </button>
      </div>

      <div style={styles.separator} />

      {/* Canvas preset */}
      <div style={styles.toolGroup}>
        <label style={styles.label}>Size:</label>
        <select
          value={canvas.preset}
          onChange={handlePresetChange}
          style={styles.select}
        >
          <option value="4x6">4x6 Print</option>
          <option value="2x6_strip">2x6 Strip</option>
          <option value="1080x1080">1080x1080 (Square)</option>
          <option value="1080x1920">1080x1920 (Story)</option>
          <option value="custom">Custom</option>
        </select>
        {canvas.preset === 'custom' && (
          <>
            <input
              type="number"
              value={canvas.width}
              onChange={(e) =>
                setCanvasSize({ ...canvas, width: parseInt(e.target.value) || 100 })
              }
              style={styles.numberInput}
              min={1}
              max={10000}
            />
            <span>x</span>
            <input
              type="number"
              value={canvas.height}
              onChange={(e) =>
                setCanvasSize({ ...canvas, height: parseInt(e.target.value) || 100 })
              }
              style={styles.numberInput}
              min={1}
              max={10000}
            />
          </>
        )}
      </div>

      <div style={styles.separator} />

      {/* Grid */}
      <div style={styles.toolGroup}>
        <label style={styles.checkboxLabel}>
          <input
            type="checkbox"
            checked={showGrid}
            onChange={(e) => setShowGrid(e.target.checked)}
          />
          Grid
        </label>
        <label style={styles.checkboxLabel}>
          <input
            type="checkbox"
            checked={snapToGrid}
            onChange={(e) => setSnapToGrid(e.target.checked)}
          />
          Snap
        </label>
      </div>

      <div style={{ flex: 1 }} />

      {/* Actions */}
      <div style={styles.toolGroup}>
        <button onClick={onSave} style={styles.primaryButton}>
          Save
        </button>
        <button onClick={onExport} style={styles.exportButton}>
          Export PNG
        </button>
      </div>
    </div>
  );
};

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const styles: Record<string, React.CSSProperties> = {
  toolbar: {
    display: 'flex',
    alignItems: 'center',
    padding: '8px 16px',
    backgroundColor: '#fff',
    borderBottom: '1px solid #e0e0e0',
    gap: '4px',
    flexWrap: 'wrap',
    minHeight: 52,
  },
  toolGroup: {
    display: 'flex',
    alignItems: 'center',
    gap: '4px',
  },
  toolButton: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    padding: '6px 10px',
    border: '1px solid transparent',
    borderRadius: 6,
    background: 'transparent',
    cursor: 'pointer',
    fontSize: 11,
    color: '#555',
    transition: 'all 0.15s',
  },
  toolButtonActive: {
    backgroundColor: '#e8f0fe',
    borderColor: '#4285f4',
    color: '#4285f4',
  },
  toolIcon: {
    fontSize: 18,
    lineHeight: '20px',
  },
  toolLabel: {
    fontSize: 10,
    marginTop: 2,
  },
  iconButton: {
    width: 32,
    height: 32,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    border: '1px solid #e0e0e0',
    borderRadius: 6,
    background: '#fff',
    cursor: 'pointer',
    fontSize: 16,
  },
  separator: {
    width: 1,
    height: 32,
    backgroundColor: '#e0e0e0',
    margin: '0 8px',
  },
  zoomLabel: {
    fontSize: 12,
    minWidth: 44,
    textAlign: 'center',
  },
  label: {
    fontSize: 12,
    color: '#666',
    marginRight: 4,
  },
  select: {
    fontSize: 12,
    padding: '4px 8px',
    borderRadius: 4,
    border: '1px solid #ccc',
  },
  numberInput: {
    width: 60,
    fontSize: 12,
    padding: '4px 6px',
    borderRadius: 4,
    border: '1px solid #ccc',
    textAlign: 'center',
  },
  checkboxLabel: {
    display: 'flex',
    alignItems: 'center',
    gap: 4,
    fontSize: 12,
    cursor: 'pointer',
  },
  primaryButton: {
    padding: '8px 16px',
    borderRadius: 6,
    border: 'none',
    backgroundColor: '#4285f4',
    color: '#fff',
    fontSize: 13,
    fontWeight: 600,
    cursor: 'pointer',
  },
  exportButton: {
    padding: '8px 16px',
    borderRadius: 6,
    border: '1px solid #4285f4',
    backgroundColor: '#fff',
    color: '#4285f4',
    fontSize: 13,
    fontWeight: 600,
    cursor: 'pointer',
  },
};

export default Toolbar;
