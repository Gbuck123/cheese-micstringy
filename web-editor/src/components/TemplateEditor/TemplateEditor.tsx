/**
 * TemplateEditor.tsx
 *
 * The main template editor component that composes:
 *   - Toolbar (top)
 *   - Layers panel (left)
 *   - Canvas (center)
 *   - Properties panel (right)
 *
 * Also handles:
 *   - Image import dialog
 *   - Save/export logic
 *   - Container resize tracking
 */

import React, { useRef, useState, useEffect, useCallback } from 'react';
import { v4 as uuid } from 'uuid';
import FabricCanvas from './FabricCanvas';
import Toolbar from './Toolbar';
import LayersPanel from './LayersPanel';
import PropertiesPanel from './PropertiesPanel';
import { useEditorStore } from '../../hooks/useEditorStore';
import { createDefaultImageElement } from '../../utils/fabric-helpers';
import type { PhotoBoothTemplate, CanvasSize, PRESET_SIZES } from '../../types/template';

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

interface TemplateEditorProps {
  /** Pre-existing template to load (edit mode) */
  initialTemplate?: PhotoBoothTemplate;
  /** Callback when the user saves */
  onSave?: (template: PhotoBoothTemplate) => void;
  /** Callback when the user exports a PNG */
  onExportPNG?: (blob: Blob) => void;
  /** Function to upload an image and return its URL and asset ID */
  uploadImage?: (file: File) => Promise<{ url: string; assetId: string }>;
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

const TemplateEditor: React.FC<TemplateEditorProps> = ({
  initialTemplate,
  onSave,
  onExportPNG,
  uploadImage,
}) => {
  const { initTemplate, newTemplate, toJSON, addElement } = useEditorStore();
  const exportRef = useRef<(() => Promise<Blob>) | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [canvasDims, setCanvasDims] = useState({ width: 800, height: 600 });
  const [isExporting, setIsExporting] = useState(false);

  // --- Initialize template ---
  useEffect(() => {
    if (initialTemplate) {
      initTemplate(initialTemplate);
    } else {
      newTemplate({
        preset: '4x6',
        width: 1200,
        height: 1800,
        dpi: 300,
      });
    }
  }, [initialTemplate, initTemplate, newTemplate]);

  // --- Track container size ---
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const observer = new ResizeObserver((entries) => {
      const { width, height } = entries[0].contentRect;
      setCanvasDims({ width, height });
    });

    observer.observe(container);
    return () => observer.disconnect();
  }, []);

  // --- Save ---
  const handleSave = useCallback(() => {
    const template = toJSON();
    onSave?.(template);
  }, [toJSON, onSave]);

  // --- Export ---
  const handleExport = useCallback(async () => {
    if (!exportRef.current) return;
    setIsExporting(true);
    try {
      const blob = await exportRef.current();
      onExportPNG?.(blob);

      // Also trigger a download
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'template.png';
      a.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      console.error('Export failed:', err);
    } finally {
      setIsExporting(false);
    }
  }, [onExportPNG]);

  // --- Image import ---
  const handleImportImage = useCallback(() => {
    fileInputRef.current?.click();
  }, []);

  const handleFileChange = useCallback(
    async (e: React.ChangeEvent<HTMLInputElement>) => {
      const file = e.target.files?.[0];
      if (!file) return;

      // Read file to get dimensions
      const objectUrl = URL.createObjectURL(file);
      const img = new Image();
      img.src = objectUrl;

      img.onload = async () => {
        let url = objectUrl;
        let assetId = uuid();

        // If uploadImage is provided, upload to S3
        if (uploadImage) {
          try {
            const result = await uploadImage(file);
            url = result.url;
            assetId = result.assetId;
            URL.revokeObjectURL(objectUrl);
          } catch (err) {
            console.error('Upload failed:', err);
            // Fallback to local object URL
          }
        }

        // Scale image to fit within canvas if too large
        const maxDim = 400;
        const scale = Math.min(maxDim / img.width, maxDim / img.height, 1);
        const width = img.width * scale;
        const height = img.height * scale;

        addElement(createDefaultImageElement(url, assetId, width, height));
      };

      // Reset input so the same file can be selected again
      e.target.value = '';
    },
    [addElement, uploadImage],
  );

  return (
    <div style={styles.container}>
      {/* Toolbar */}
      <Toolbar
        onExport={handleExport}
        onImportImage={handleImportImage}
        onSave={handleSave}
      />

      {/* Main area: layers + canvas + properties */}
      <div style={styles.mainArea}>
        {/* Layers panel (left) */}
        <LayersPanel />

        {/* Canvas (center) */}
        <div ref={containerRef} style={styles.canvasContainer}>
          <FabricCanvas
            containerWidth={canvasDims.width}
            containerHeight={canvasDims.height}
            onExport={onExportPNG}
            exportRef={exportRef}
          />
          {isExporting && (
            <div style={styles.exportOverlay}>Exporting...</div>
          )}
        </div>

        {/* Properties panel (right) */}
        <PropertiesPanel />
      </div>

      {/* Hidden file input for image import */}
      <input
        ref={fileInputRef}
        type="file"
        accept="image/*"
        style={{ display: 'none' }}
        onChange={handleFileChange}
      />
    </div>
  );
};

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const styles: Record<string, React.CSSProperties> = {
  container: {
    display: 'flex',
    flexDirection: 'column',
    height: '100vh',
    fontFamily:
      '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
  },
  mainArea: {
    display: 'flex',
    flex: 1,
    overflow: 'hidden',
  },
  canvasContainer: {
    flex: 1,
    position: 'relative',
    overflow: 'hidden',
  },
  exportOverlay: {
    position: 'absolute',
    inset: 0,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(255, 255, 255, 0.8)',
    fontSize: 18,
    fontWeight: 600,
    color: '#333',
    zIndex: 100,
  },
};

export default TemplateEditor;
