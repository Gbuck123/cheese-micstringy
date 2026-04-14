/**
 * AssetManager.tsx
 *
 * Upload, manage, and browse images/logos/stickers for use in templates.
 *
 * Features:
 *   - Drag-and-drop file upload
 *   - Image crop (basic)
 *   - Asset library browsing (user's uploads + pre-made stickers)
 *   - Template library (pre-made templates to customize)
 *   - S3/CloudFront integration for storage
 *
 * ARCHITECTURE:
 *
 * ┌─────────────────────┐       ┌─────────────────────┐
 * │   Web Editor         │       │   Asset API          │
 * │   (AssetManager)     │──────▶│   (REST / GraphQL)   │
 * └─────────────────────┘       └─────────┬───────────┘
 *                                         │
 *                                ┌────────▼────────┐
 *                                │   S3 Bucket      │
 *                                │   (assets/)      │
 *                                └────────┬────────┘
 *                                         │
 *                                ┌────────▼────────┐
 *                                │   CloudFront     │
 *                                │   (CDN)          │
 *                                └─────────────────┘
 *
 * Upload flow:
 *   1. Client requests a presigned S3 upload URL from the API
 *   2. Client uploads directly to S3 (bypasses our server)
 *   3. Client notifies API of successful upload
 *   4. API creates asset record in database
 *   5. CloudFront serves the asset via CDN
 */

import React, { useState, useCallback, useMemo } from 'react';
import { useDropzone } from 'react-dropzone';
import { v4 as uuid } from 'uuid';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface Asset {
  id: string;
  name: string;
  url: string;
  thumbnailUrl: string;
  type: 'image' | 'sticker' | 'logo' | 'background';
  width: number;
  height: number;
  fileSize: number;
  mimeType: string;
  createdAt: string;
  tags: string[];
}

export interface TemplatePreset {
  id: string;
  name: string;
  thumbnailUrl: string;
  category: string;
  description: string;
  templateJson: string; // URL to the template JSON
}

interface AssetManagerProps {
  /** Existing assets to display */
  assets?: Asset[];
  /** Pre-made templates */
  templates?: TemplatePreset[];
  /** Called when user selects an asset to add to the canvas */
  onSelectAsset: (asset: Asset) => void;
  /** Called when user selects a template to load */
  onSelectTemplate?: (template: TemplatePreset) => void;
  /** Upload function: receives file, returns asset */
  onUpload: (file: File) => Promise<Asset>;
  /** Delete function */
  onDelete?: (assetId: string) => Promise<void>;
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

const AssetManager: React.FC<AssetManagerProps> = ({
  assets = [],
  templates = [],
  onSelectAsset,
  onSelectTemplate,
  onUpload,
  onDelete,
}) => {
  const [activeTab, setActiveTab] = useState<
    'uploads' | 'stickers' | 'backgrounds' | 'templates'
  >('uploads');
  const [uploading, setUploading] = useState(false);
  const [uploadProgress, setUploadProgress] = useState(0);
  const [searchQuery, setSearchQuery] = useState('');
  const [error, setError] = useState<string | null>(null);

  // --- File upload via dropzone ---
  const onDrop = useCallback(
    async (acceptedFiles: File[]) => {
      setError(null);
      setUploading(true);

      for (let i = 0; i < acceptedFiles.length; i++) {
        const file = acceptedFiles[i];
        setUploadProgress(((i + 1) / acceptedFiles.length) * 100);

        try {
          await onUpload(file);
        } catch (err) {
          setError(`Failed to upload ${file.name}: ${(err as Error).message}`);
        }
      }

      setUploading(false);
      setUploadProgress(0);
    },
    [onUpload],
  );

  const { getRootProps, getInputProps, isDragActive } = useDropzone({
    onDrop,
    accept: {
      'image/*': ['.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp'],
    },
    maxSize: 10 * 1024 * 1024, // 10MB
    multiple: true,
  });

  // --- Filtered assets ---
  const filteredAssets = useMemo(() => {
    let filtered = assets;

    // Filter by tab
    switch (activeTab) {
      case 'uploads':
        filtered = assets.filter(
          (a) => a.type === 'image' || a.type === 'logo',
        );
        break;
      case 'stickers':
        filtered = assets.filter((a) => a.type === 'sticker');
        break;
      case 'backgrounds':
        filtered = assets.filter((a) => a.type === 'background');
        break;
    }

    // Search filter
    if (searchQuery) {
      const q = searchQuery.toLowerCase();
      filtered = filtered.filter(
        (a) =>
          a.name.toLowerCase().includes(q) ||
          a.tags.some((t) => t.toLowerCase().includes(q)),
      );
    }

    return filtered;
  }, [assets, activeTab, searchQuery]);

  return (
    <div style={styles.container}>
      {/* Header */}
      <div style={styles.header}>
        <h3 style={styles.title}>Assets</h3>
        <input
          type="text"
          placeholder="Search..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          style={styles.searchInput}
        />
      </div>

      {/* Tabs */}
      <div style={styles.tabs}>
        {(
          [
            { id: 'uploads', label: 'My Uploads' },
            { id: 'stickers', label: 'Stickers' },
            { id: 'backgrounds', label: 'Backgrounds' },
            { id: 'templates', label: 'Templates' },
          ] as const
        ).map((tab) => (
          <button
            key={tab.id}
            onClick={() => setActiveTab(tab.id)}
            style={{
              ...styles.tab,
              ...(activeTab === tab.id ? styles.tabActive : {}),
            }}
          >
            {tab.label}
          </button>
        ))}
      </div>

      {/* Error */}
      {error && (
        <div style={styles.error}>
          {error}
          <button
            onClick={() => setError(null)}
            style={styles.errorClose}
          >
            x
          </button>
        </div>
      )}

      {/* Content */}
      <div style={styles.content}>
        {activeTab !== 'templates' && (
          <>
            {/* Upload zone */}
            <div
              {...getRootProps()}
              style={{
                ...styles.dropzone,
                ...(isDragActive ? styles.dropzoneActive : {}),
              }}
            >
              <input {...getInputProps()} />
              {uploading ? (
                <div>
                  <div style={styles.progressBar}>
                    <div
                      style={{
                        ...styles.progressFill,
                        width: `${uploadProgress}%`,
                      }}
                    />
                  </div>
                  <p style={styles.dropzoneText}>Uploading...</p>
                </div>
              ) : isDragActive ? (
                <p style={styles.dropzoneText}>Drop files here...</p>
              ) : (
                <p style={styles.dropzoneText}>
                  Drag & drop images here, or click to browse
                </p>
              )}
            </div>

            {/* Asset grid */}
            <div style={styles.assetGrid}>
              {filteredAssets.map((asset) => (
                <div
                  key={asset.id}
                  style={styles.assetCard}
                  onClick={() => onSelectAsset(asset)}
                  title={asset.name}
                >
                  <div style={styles.assetImageWrapper}>
                    <img
                      src={asset.thumbnailUrl || asset.url}
                      alt={asset.name}
                      style={styles.assetImage}
                      loading="lazy"
                    />
                  </div>
                  <div style={styles.assetInfo}>
                    <span style={styles.assetName}>{asset.name}</span>
                    <span style={styles.assetMeta}>
                      {asset.width}x{asset.height}
                    </span>
                  </div>
                  {onDelete && (
                    <button
                      onClick={(e) => {
                        e.stopPropagation();
                        onDelete(asset.id);
                      }}
                      style={styles.deleteButton}
                      title="Delete"
                    >
                      x
                    </button>
                  )}
                </div>
              ))}
              {filteredAssets.length === 0 && (
                <p style={styles.emptyState}>
                  {searchQuery
                    ? 'No assets match your search.'
                    : 'No assets yet. Upload some images!'}
                </p>
              )}
            </div>
          </>
        )}

        {/* Templates tab */}
        {activeTab === 'templates' && (
          <div style={styles.templateGrid}>
            {templates.map((template) => (
              <div
                key={template.id}
                style={styles.templateCard}
                onClick={() => onSelectTemplate?.(template)}
              >
                <img
                  src={template.thumbnailUrl}
                  alt={template.name}
                  style={styles.templateImage}
                  loading="lazy"
                />
                <div style={styles.templateInfo}>
                  <span style={styles.templateName}>{template.name}</span>
                  <span style={styles.templateCategory}>
                    {template.category}
                  </span>
                </div>
              </div>
            ))}
            {templates.length === 0 && (
              <p style={styles.emptyState}>
                No template presets available.
              </p>
            )}
          </div>
        )}
      </div>
    </div>
  );
};

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const styles: Record<string, React.CSSProperties> = {
  container: {
    width: 320,
    backgroundColor: '#fff',
    borderRadius: 8,
    boxShadow: '0 4px 16px rgba(0,0,0,0.1)',
    overflow: 'hidden',
    display: 'flex',
    flexDirection: 'column',
    maxHeight: 600,
  },
  header: {
    padding: '12px 16px',
    borderBottom: '1px solid #e0e0e0',
  },
  title: {
    margin: '0 0 8px',
    fontSize: 14,
    fontWeight: 600,
  },
  searchInput: {
    width: '100%',
    padding: '6px 10px',
    border: '1px solid #ddd',
    borderRadius: 6,
    fontSize: 12,
    boxSizing: 'border-box',
  },
  tabs: {
    display: 'flex',
    borderBottom: '1px solid #e0e0e0',
    flexShrink: 0,
  },
  tab: {
    flex: 1,
    padding: '8px 4px',
    border: 'none',
    background: 'transparent',
    cursor: 'pointer',
    fontSize: 11,
    color: '#666',
    borderBottom: '2px solid transparent',
    whiteSpace: 'nowrap',
  },
  tabActive: {
    color: '#4285f4',
    borderBottomColor: '#4285f4',
    fontWeight: 600,
  },
  content: {
    flex: 1,
    overflowY: 'auto',
    padding: 12,
  },
  dropzone: {
    border: '2px dashed #ddd',
    borderRadius: 8,
    padding: 16,
    textAlign: 'center',
    cursor: 'pointer',
    marginBottom: 12,
    transition: 'all 0.2s',
  },
  dropzoneActive: {
    borderColor: '#4285f4',
    backgroundColor: '#e8f0fe',
  },
  dropzoneText: {
    fontSize: 12,
    color: '#888',
    margin: 0,
  },
  progressBar: {
    height: 4,
    backgroundColor: '#e0e0e0',
    borderRadius: 2,
    overflow: 'hidden',
    marginBottom: 8,
  },
  progressFill: {
    height: '100%',
    backgroundColor: '#4285f4',
    borderRadius: 2,
    transition: 'width 0.3s',
  },
  assetGrid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(3, 1fr)',
    gap: 8,
  },
  assetCard: {
    position: 'relative',
    borderRadius: 6,
    overflow: 'hidden',
    border: '1px solid #eee',
    cursor: 'pointer',
    transition: 'transform 0.1s, box-shadow 0.1s',
  },
  assetImageWrapper: {
    aspectRatio: '1',
    overflow: 'hidden',
    backgroundColor: '#f5f5f5',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
  },
  assetImage: {
    width: '100%',
    height: '100%',
    objectFit: 'cover',
  },
  assetInfo: {
    padding: '4px 6px',
  },
  assetName: {
    display: 'block',
    fontSize: 10,
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
  },
  assetMeta: {
    fontSize: 9,
    color: '#aaa',
  },
  deleteButton: {
    position: 'absolute',
    top: 4,
    right: 4,
    width: 18,
    height: 18,
    borderRadius: '50%',
    border: 'none',
    backgroundColor: 'rgba(0,0,0,0.5)',
    color: '#fff',
    fontSize: 10,
    cursor: 'pointer',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    opacity: 0,
    transition: 'opacity 0.2s',
  },
  templateGrid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(2, 1fr)',
    gap: 12,
  },
  templateCard: {
    borderRadius: 8,
    overflow: 'hidden',
    border: '1px solid #eee',
    cursor: 'pointer',
    transition: 'transform 0.1s',
  },
  templateImage: {
    width: '100%',
    aspectRatio: '3/4',
    objectFit: 'cover',
  },
  templateInfo: {
    padding: '8px',
  },
  templateName: {
    display: 'block',
    fontSize: 12,
    fontWeight: 600,
  },
  templateCategory: {
    fontSize: 10,
    color: '#888',
  },
  emptyState: {
    gridColumn: '1 / -1',
    textAlign: 'center',
    color: '#999',
    fontSize: 12,
    padding: 20,
  },
  error: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    padding: '8px 16px',
    backgroundColor: '#fce8e6',
    color: '#c5221f',
    fontSize: 12,
  },
  errorClose: {
    border: 'none',
    background: 'transparent',
    color: '#c5221f',
    cursor: 'pointer',
    fontSize: 14,
  },
};

export default AssetManager;
