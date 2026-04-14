/**
 * FontManager.tsx
 *
 * Manages custom font loading for the template editor:
 *   1. Google Fonts integration (browse, select, load)
 *   2. Custom font upload (TTF, OTF, WOFF2)
 *   3. Font embedding for export
 *
 * FONT RENDERING CONSISTENCY (Web <-> iPad):
 *
 * The challenge: fonts must look identical in the web editor and the iPad app.
 *
 * Strategy:
 *   1. For Google Fonts: both web and iPad load the same TTF file from our CDN.
 *      - Web: loaded via @font-face CSS
 *      - iPad: downloaded at template-load time, registered with CTFontManagerRegisterFontsForURL
 *
 *   2. For custom uploaded fonts:
 *      - User uploads a .ttf or .otf file
 *      - We store it in S3 with a stable URL
 *      - The template JSON includes the font URL in the `urls` field
 *      - Both web and iPad fetch from the same URL
 *
 *   3. Font embedding in exported templates:
 *      - The template JSON's `fonts` array lists all required fonts
 *      - Each font has `urls.ttf` and `urls.woff2` fields
 *      - The iPad app downloads and caches all fonts before rendering
 *
 *   4. Fallback chain:
 *      - If a font fails to load, both platforms fall back to:
 *        Web: system-ui, sans-serif
 *        iPad: San Francisco (system font)
 *      - The template JSON can include a `fallbackFamily` field
 *
 * IMPLEMENTATION NOTES:
 *   - We use the Web Font Loader library for reliable font loading
 *   - Custom fonts are loaded via @font-face injection
 *   - Google Fonts are loaded via the Google Fonts CSS API
 *   - The FontManager component provides a UI for font browsing/upload
 *   - The `useEditorStore.addFont()` action registers fonts in the template
 */

import React, { useState, useCallback, useRef } from 'react';
import WebFont from 'webfontloader';
import { v4 as uuid } from 'uuid';
import { useEditorStore } from '../../hooks/useEditorStore';
import type { FontReference } from '../../types/template';

// ---------------------------------------------------------------------------
// Popular Google Fonts (curated subset for photo booth use)
// ---------------------------------------------------------------------------

const POPULAR_GOOGLE_FONTS = [
  'Playfair Display',
  'Montserrat',
  'Oswald',
  'Lato',
  'Roboto',
  'Open Sans',
  'Raleway',
  'Poppins',
  'Merriweather',
  'Lobster',
  'Pacifico',
  'Dancing Script',
  'Great Vibes',
  'Bebas Neue',
  'Satisfy',
  'Sacramento',
  'Caveat',
  'Permanent Marker',
  'Press Start 2P',
  'Anton',
  'Abril Fatface',
  'Comfortaa',
  'Righteous',
  'Bungee',
  'Indie Flower',
  'Orbitron',
  'Titan One',
  'Bangers',
  'Alfa Slab One',
  'Fredoka One',
];

// ---------------------------------------------------------------------------
// Font loading utilities
// ---------------------------------------------------------------------------

/**
 * Load a Google Font into the page using WebFontLoader.
 * Returns a FontReference that can be stored in the template.
 */
export function loadGoogleFont(
  family: string,
  weight: number = 400,
  style: 'normal' | 'italic' = 'normal',
): Promise<FontReference> {
  return new Promise((resolve, reject) => {
    const fontSpec = `${family}:${weight}${style === 'italic' ? 'i' : ''}`;

    WebFont.load({
      google: {
        families: [fontSpec],
      },
      active: () => {
        resolve({
          family,
          googleFontId: family.replace(/\s+/g, '+'),
          weight,
          style,
          urls: {
            // Google Fonts provides WOFF2 via CSS; for the iPad app,
            // we generate a direct TTF URL from the Google Fonts API.
            woff2: `https://fonts.googleapis.com/css2?family=${encodeURIComponent(family)}:wght@${weight}&display=swap`,
            ttf: `https://fonts.gstatic.com/s/${family.toLowerCase().replace(/\s+/g, '')}/v1/${family.replace(/\s+/g, '')}-Regular.ttf`,
          },
        });
      },
      inactive: () => {
        reject(new Error(`Failed to load Google Font: ${family}`));
      },
    });
  });
}

/**
 * Load a custom font file (TTF, OTF, WOFF2) via @font-face injection.
 * The file should be uploaded to S3 first; pass the URL here.
 */
export function loadCustomFont(
  family: string,
  url: string,
  weight: number = 400,
  style: 'normal' | 'italic' = 'normal',
): Promise<FontReference> {
  return new Promise((resolve, reject) => {
    const fontId = uuid();

    // Determine format from URL extension
    const ext = url.split('.').pop()?.toLowerCase();
    const format =
      ext === 'woff2' ? 'woff2' :
      ext === 'woff' ? 'woff' :
      ext === 'otf' ? 'opentype' :
      'truetype';

    // Inject @font-face
    const styleEl = document.createElement('style');
    styleEl.textContent = `
      @font-face {
        font-family: '${family}';
        src: url('${url}') format('${format}');
        font-weight: ${weight};
        font-style: ${style};
        font-display: swap;
      }
    `;
    document.head.appendChild(styleEl);

    // Use FontFace API to detect when the font is ready
    if ('fonts' in document) {
      const fontFace = new FontFace(family, `url(${url})`, {
        weight: String(weight),
        style,
      });

      fontFace.load().then(
        (loaded) => {
          document.fonts.add(loaded);
          const urls: FontReference['urls'] = {};
          if (ext === 'woff2') urls.woff2 = url;
          else if (ext === 'ttf') urls.ttf = url;
          else if (ext === 'otf') urls.otf = url;
          else urls.ttf = url;

          resolve({
            family,
            customFontId: fontId,
            weight,
            style,
            urls,
          });
        },
        (err) => {
          reject(new Error(`Failed to load custom font: ${err.message}`));
        },
      );
    } else {
      // Fallback: assume it loaded after a short delay
      setTimeout(() => {
        resolve({
          family,
          customFontId: fontId,
          weight,
          style,
          urls: { ttf: url },
        });
      }, 1000);
    }
  });
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

interface FontManagerProps {
  /** Function to upload a font file and return its CDN URL */
  uploadFont?: (file: File) => Promise<string>;
  /** Called when a font is selected/loaded */
  onFontSelect?: (font: FontReference) => void;
}

const FontManager: React.FC<FontManagerProps> = ({
  uploadFont,
  onFontSelect,
}) => {
  const { addFont, fonts } = useEditorStore();
  const [searchQuery, setSearchQuery] = useState('');
  const [loadingFont, setLoadingFont] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [activeTab, setActiveTab] = useState<'google' | 'custom' | 'loaded'>(
    'google',
  );
  const fileInputRef = useRef<HTMLInputElement>(null);

  const filteredFonts = POPULAR_GOOGLE_FONTS.filter((f) =>
    f.toLowerCase().includes(searchQuery.toLowerCase()),
  );

  const handleLoadGoogleFont = useCallback(
    async (family: string) => {
      setLoadingFont(family);
      setError(null);
      try {
        const fontRef = await loadGoogleFont(family);
        addFont(fontRef);
        onFontSelect?.(fontRef);
      } catch (err) {
        setError(`Failed to load "${family}"`);
      } finally {
        setLoadingFont(null);
      }
    },
    [addFont, onFontSelect],
  );

  const handleUploadFont = useCallback(
    async (e: React.ChangeEvent<HTMLInputElement>) => {
      const file = e.target.files?.[0];
      if (!file) return;

      setLoadingFont(file.name);
      setError(null);

      try {
        // Extract family name from filename
        const family = file.name
          .replace(/\.(ttf|otf|woff|woff2)$/i, '')
          .replace(/[-_]/g, ' ');

        let url: string;
        if (uploadFont) {
          url = await uploadFont(file);
        } else {
          // Local fallback: create an object URL
          url = URL.createObjectURL(file);
        }

        const fontRef = await loadCustomFont(family, url);
        addFont(fontRef);
        onFontSelect?.(fontRef);
      } catch (err) {
        setError(`Failed to load font: ${(err as Error).message}`);
      } finally {
        setLoadingFont(null);
        e.target.value = '';
      }
    },
    [addFont, onFontSelect, uploadFont],
  );

  return (
    <div style={styles.container}>
      <div style={styles.header}>
        <h3 style={styles.title}>Fonts</h3>
      </div>

      {/* Tabs */}
      <div style={styles.tabs}>
        {(['google', 'custom', 'loaded'] as const).map((tab) => (
          <button
            key={tab}
            onClick={() => setActiveTab(tab)}
            style={{
              ...styles.tab,
              ...(activeTab === tab ? styles.tabActive : {}),
            }}
          >
            {tab === 'google'
              ? 'Google Fonts'
              : tab === 'custom'
              ? 'Upload'
              : `Loaded (${fonts.length})`}
          </button>
        ))}
      </div>

      {/* Error */}
      {error && <div style={styles.error}>{error}</div>}

      {/* Google Fonts tab */}
      {activeTab === 'google' && (
        <div style={styles.tabContent}>
          <input
            type="text"
            placeholder="Search fonts..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            style={styles.searchInput}
          />
          <div style={styles.fontList}>
            {filteredFonts.map((family) => {
              const isLoaded = fonts.some((f) => f.family === family);
              return (
                <div
                  key={family}
                  style={styles.fontItem}
                  onClick={() => !isLoaded && handleLoadGoogleFont(family)}
                >
                  <span style={styles.fontName}>{family}</span>
                  {loadingFont === family && (
                    <span style={styles.loading}>Loading...</span>
                  )}
                  {isLoaded && (
                    <span style={styles.loadedBadge}>Loaded</span>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* Upload tab */}
      {activeTab === 'custom' && (
        <div style={styles.tabContent}>
          <div style={styles.uploadArea}>
            <p style={styles.uploadText}>
              Upload a custom font file (TTF, OTF, WOFF2)
            </p>
            <button
              onClick={() => fileInputRef.current?.click()}
              style={styles.uploadButton}
              disabled={!!loadingFont}
            >
              {loadingFont ? 'Uploading...' : 'Choose File'}
            </button>
            <input
              ref={fileInputRef}
              type="file"
              accept=".ttf,.otf,.woff,.woff2"
              onChange={handleUploadFont}
              style={{ display: 'none' }}
            />
          </div>
          <div style={styles.infoBox}>
            <strong>Font compatibility:</strong>
            <ul style={styles.infoList}>
              <li>TTF files work on both web and iPad</li>
              <li>OTF files work on both, but TTF is preferred for iOS</li>
              <li>WOFF2 is web-only; upload TTF for cross-platform use</li>
              <li>Always test your template on the iPad app after adding custom fonts</li>
            </ul>
          </div>
        </div>
      )}

      {/* Loaded fonts tab */}
      {activeTab === 'loaded' && (
        <div style={styles.tabContent}>
          {fonts.length === 0 ? (
            <p style={styles.emptyState}>
              No fonts loaded yet. Add Google Fonts or upload custom fonts.
            </p>
          ) : (
            <div style={styles.fontList}>
              {fonts.map((font) => (
                <div key={`${font.family}-${font.weight}`} style={styles.fontItem}>
                  <div>
                    <span
                      style={{
                        ...styles.fontName,
                        fontFamily: font.family,
                        fontWeight: font.weight,
                      }}
                    >
                      {font.family}
                    </span>
                    <span style={styles.fontMeta}>
                      {font.weight} {font.style}
                      {font.googleFontId ? ' (Google)' : ' (Custom)'}
                    </span>
                  </div>
                  <button
                    onClick={() => onFontSelect?.(font)}
                    style={styles.useButton}
                  >
                    Use
                  </button>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
};

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const styles: Record<string, React.CSSProperties> = {
  container: {
    width: 300,
    backgroundColor: '#fff',
    borderRadius: 8,
    boxShadow: '0 4px 16px rgba(0,0,0,0.1)',
    overflow: 'hidden',
  },
  header: {
    padding: '12px 16px',
    borderBottom: '1px solid #e0e0e0',
  },
  title: {
    margin: 0,
    fontSize: 14,
    fontWeight: 600,
  },
  tabs: {
    display: 'flex',
    borderBottom: '1px solid #e0e0e0',
  },
  tab: {
    flex: 1,
    padding: '10px',
    border: 'none',
    background: 'transparent',
    cursor: 'pointer',
    fontSize: 12,
    color: '#666',
    borderBottom: '2px solid transparent',
  },
  tabActive: {
    color: '#4285f4',
    borderBottomColor: '#4285f4',
    fontWeight: 600,
  },
  tabContent: {
    padding: '12px',
    maxHeight: 400,
    overflowY: 'auto',
  },
  searchInput: {
    width: '100%',
    padding: '8px 12px',
    border: '1px solid #ddd',
    borderRadius: 6,
    fontSize: 13,
    marginBottom: 8,
    boxSizing: 'border-box',
  },
  fontList: {
    display: 'flex',
    flexDirection: 'column',
    gap: 2,
  },
  fontItem: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    padding: '8px 10px',
    borderRadius: 6,
    cursor: 'pointer',
    transition: 'background 0.1s',
  },
  fontName: {
    fontSize: 13,
  },
  fontMeta: {
    display: 'block',
    fontSize: 10,
    color: '#888',
    marginTop: 2,
  },
  loading: {
    fontSize: 11,
    color: '#4285f4',
  },
  loadedBadge: {
    fontSize: 10,
    color: '#34a853',
    backgroundColor: '#e6f4ea',
    padding: '2px 8px',
    borderRadius: 10,
  },
  uploadArea: {
    padding: 20,
    border: '2px dashed #ddd',
    borderRadius: 8,
    textAlign: 'center',
    marginBottom: 12,
  },
  uploadText: {
    fontSize: 12,
    color: '#666',
    margin: '0 0 12px',
  },
  uploadButton: {
    padding: '8px 20px',
    border: '1px solid #4285f4',
    borderRadius: 6,
    backgroundColor: '#fff',
    color: '#4285f4',
    fontSize: 13,
    cursor: 'pointer',
  },
  useButton: {
    padding: '4px 12px',
    border: '1px solid #ddd',
    borderRadius: 4,
    backgroundColor: '#fff',
    cursor: 'pointer',
    fontSize: 11,
  },
  infoBox: {
    fontSize: 11,
    color: '#555',
    backgroundColor: '#f8f9fa',
    borderRadius: 6,
    padding: 12,
    lineHeight: 1.5,
  },
  infoList: {
    margin: '8px 0 0',
    paddingLeft: 16,
  },
  error: {
    padding: '8px 16px',
    backgroundColor: '#fce8e6',
    color: '#c5221f',
    fontSize: 12,
  },
  emptyState: {
    textAlign: 'center',
    color: '#999',
    fontSize: 12,
    padding: 20,
  },
};

export default FontManager;
