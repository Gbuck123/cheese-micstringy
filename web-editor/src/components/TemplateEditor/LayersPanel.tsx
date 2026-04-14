/**
 * LayersPanel.tsx
 *
 * A Photoshop/Figma-style layers panel showing all elements sorted by z-index.
 * Supports:
 *   - Click to select
 *   - Toggle visibility (eye icon)
 *   - Toggle lock
 *   - Drag to reorder (simplified: uses bring forward/send backward buttons)
 *   - Right-click context menu for layer operations
 */

import React, { useState } from 'react';
import { useEditorStore } from '../../hooks/useEditorStore';
import type { TemplateElement } from '../../types/template';

const ELEMENT_TYPE_ICONS: Record<string, string> = {
  text: 'T',
  image: '🖼',
  shape: '◻',
  photo_zone: '📷',
  group: '📁',
};

const LayersPanel: React.FC = () => {
  const {
    elements,
    selectedIds,
    select,
    toggleVisibility,
    toggleLock,
    bringToFront,
    sendToBack,
    bringForward,
    sendBackward,
    removeElement,
    duplicateElement,
  } = useEditorStore();

  const [contextMenu, setContextMenu] = useState<{
    x: number;
    y: number;
    elementId: string;
  } | null>(null);

  // Sort by zIndex descending (highest on top in the panel)
  const sortedElements = [...elements].sort((a, b) => b.zIndex - a.zIndex);

  const handleClick = (id: string, e: React.MouseEvent) => {
    if (e.shiftKey || e.metaKey || e.ctrlKey) {
      // Multi-select
      const newIds = selectedIds.includes(id)
        ? selectedIds.filter((sid) => sid !== id)
        : [...selectedIds, id];
      select(newIds);
    } else {
      select([id]);
    }
  };

  const handleContextMenu = (id: string, e: React.MouseEvent) => {
    e.preventDefault();
    setContextMenu({ x: e.clientX, y: e.clientY, elementId: id });
    select([id]);
  };

  const closeContextMenu = () => setContextMenu(null);

  return (
    <div style={styles.panel} onClick={closeContextMenu}>
      <div style={styles.header}>
        <span style={styles.headerTitle}>Layers</span>
        <span style={styles.layerCount}>{elements.length}</span>
      </div>

      <div style={styles.layerList}>
        {sortedElements.map((el) => (
          <div
            key={el.id}
            onClick={(e) => handleClick(el.id, e)}
            onContextMenu={(e) => handleContextMenu(el.id, e)}
            style={{
              ...styles.layerItem,
              ...(selectedIds.includes(el.id) ? styles.layerItemSelected : {}),
              ...(el.locked ? styles.layerItemLocked : {}),
            }}
          >
            {/* Type icon */}
            <span style={styles.typeIcon}>
              {ELEMENT_TYPE_ICONS[el.type] || '?'}
            </span>

            {/* Name */}
            <span
              style={{
                ...styles.layerName,
                ...(el.visible ? {} : styles.layerNameHidden),
              }}
            >
              {el.name}
            </span>

            {/* Visibility toggle */}
            <button
              onClick={(e) => {
                e.stopPropagation();
                toggleVisibility(el.id);
              }}
              style={styles.layerAction}
              title={el.visible ? 'Hide' : 'Show'}
            >
              {el.visible ? '👁' : '👁‍🗨'}
            </button>

            {/* Lock toggle */}
            <button
              onClick={(e) => {
                e.stopPropagation();
                toggleLock(el.id);
              }}
              style={styles.layerAction}
              title={el.locked ? 'Unlock' : 'Lock'}
            >
              {el.locked ? '🔒' : '🔓'}
            </button>
          </div>
        ))}

        {elements.length === 0 && (
          <div style={styles.emptyState}>
            No elements yet. Use the toolbar to add text, shapes, images, or
            photo zones.
          </div>
        )}
      </div>

      {/* Context Menu */}
      {contextMenu && (
        <div
          style={{
            ...styles.contextMenu,
            left: contextMenu.x,
            top: contextMenu.y,
          }}
          onClick={(e) => e.stopPropagation()}
        >
          <button
            style={styles.contextMenuItem}
            onClick={() => {
              bringToFront(contextMenu.elementId);
              closeContextMenu();
            }}
          >
            Bring to Front
          </button>
          <button
            style={styles.contextMenuItem}
            onClick={() => {
              bringForward(contextMenu.elementId);
              closeContextMenu();
            }}
          >
            Bring Forward
          </button>
          <button
            style={styles.contextMenuItem}
            onClick={() => {
              sendBackward(contextMenu.elementId);
              closeContextMenu();
            }}
          >
            Send Backward
          </button>
          <button
            style={styles.contextMenuItem}
            onClick={() => {
              sendToBack(contextMenu.elementId);
              closeContextMenu();
            }}
          >
            Send to Back
          </button>
          <div style={styles.contextMenuDivider} />
          <button
            style={styles.contextMenuItem}
            onClick={() => {
              duplicateElement(contextMenu.elementId);
              closeContextMenu();
            }}
          >
            Duplicate
          </button>
          <button
            style={{
              ...styles.contextMenuItem,
              color: '#d32f2f',
            }}
            onClick={() => {
              removeElement(contextMenu.elementId);
              closeContextMenu();
            }}
          >
            Delete
          </button>
        </div>
      )}
    </div>
  );
};

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const styles: Record<string, React.CSSProperties> = {
  panel: {
    width: 240,
    backgroundColor: '#fff',
    borderLeft: '1px solid #e0e0e0',
    display: 'flex',
    flexDirection: 'column',
    height: '100%',
    userSelect: 'none',
  },
  header: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    padding: '12px 16px',
    borderBottom: '1px solid #e0e0e0',
  },
  headerTitle: {
    fontWeight: 600,
    fontSize: 14,
  },
  layerCount: {
    fontSize: 11,
    color: '#888',
    backgroundColor: '#f0f0f0',
    borderRadius: 10,
    padding: '2px 8px',
  },
  layerList: {
    flex: 1,
    overflowY: 'auto',
    padding: '4px 0',
  },
  layerItem: {
    display: 'flex',
    alignItems: 'center',
    padding: '8px 12px',
    cursor: 'pointer',
    borderBottom: '1px solid #f5f5f5',
    gap: 8,
    transition: 'background 0.1s',
  },
  layerItemSelected: {
    backgroundColor: '#e8f0fe',
    borderColor: '#c5d9f5',
  },
  layerItemLocked: {
    opacity: 0.7,
  },
  typeIcon: {
    fontSize: 14,
    width: 20,
    textAlign: 'center',
    flexShrink: 0,
  },
  layerName: {
    flex: 1,
    fontSize: 12,
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
  },
  layerNameHidden: {
    opacity: 0.4,
    textDecoration: 'line-through',
  },
  layerAction: {
    width: 24,
    height: 24,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    border: 'none',
    background: 'transparent',
    cursor: 'pointer',
    fontSize: 12,
    padding: 0,
    borderRadius: 4,
  },
  emptyState: {
    padding: 20,
    textAlign: 'center',
    color: '#999',
    fontSize: 12,
    lineHeight: 1.5,
  },
  contextMenu: {
    position: 'fixed',
    zIndex: 10000,
    backgroundColor: '#fff',
    borderRadius: 8,
    boxShadow: '0 4px 16px rgba(0,0,0,0.15)',
    padding: '4px 0',
    minWidth: 180,
  },
  contextMenuItem: {
    display: 'block',
    width: '100%',
    padding: '8px 16px',
    border: 'none',
    background: 'transparent',
    cursor: 'pointer',
    textAlign: 'left',
    fontSize: 13,
  },
  contextMenuDivider: {
    height: 1,
    backgroundColor: '#e0e0e0',
    margin: '4px 0',
  },
};

export default LayersPanel;
