/**
 * PropertiesPanel.tsx
 *
 * Right-side panel that shows editable properties for the selected element.
 * Adapts its content based on element type:
 *   - Text: font, size, color, alignment, decoration, etc.
 *   - Image: filters, crop, corner radius, border
 *   - Shape: fill, stroke, corner radius
 *   - Photo Zone: capture index, fill mode, aspect ratio, corner radius
 *   - Background: color, gradient, or image
 */

import React from 'react';
import { useEditorStore } from '../../hooks/useEditorStore';
import type {
  TemplateElement,
  TextElement,
  ImageElement,
  ShapeElement,
  PhotoZoneElement,
  TemplateBackground,
  Fill,
} from '../../types/template';

const PropertiesPanel: React.FC = () => {
  const {
    elements,
    selectedIds,
    background,
    updateElement,
    setBackground,
    pushHistory,
  } = useEditorStore();

  const selectedElements = elements.filter((el) =>
    selectedIds.includes(el.id),
  );

  if (selectedElements.length === 0) {
    return (
      <div style={styles.panel}>
        <div style={styles.header}>Properties</div>
        <BackgroundSection background={background} setBackground={setBackground} pushHistory={pushHistory} />
      </div>
    );
  }

  if (selectedElements.length > 1) {
    return (
      <div style={styles.panel}>
        <div style={styles.header}>Multiple Selection</div>
        <div style={styles.section}>
          <p style={styles.info}>{selectedElements.length} elements selected</p>
        </div>
        <CommonPropertiesSection elements={selectedElements} updateElement={updateElement} pushHistory={pushHistory} />
      </div>
    );
  }

  const element = selectedElements[0];

  return (
    <div style={styles.panel}>
      <div style={styles.header}>Properties</div>

      {/* Common properties */}
      <TransformSection element={element} updateElement={updateElement} pushHistory={pushHistory} />

      {/* Type-specific properties */}
      {element.type === 'text' && (
        <TextPropertiesSection element={element as TextElement} updateElement={updateElement} pushHistory={pushHistory} />
      )}
      {element.type === 'image' && (
        <ImagePropertiesSection element={element as ImageElement} updateElement={updateElement} pushHistory={pushHistory} />
      )}
      {element.type === 'shape' && (
        <ShapePropertiesSection element={element as ShapeElement} updateElement={updateElement} pushHistory={pushHistory} />
      )}
      {element.type === 'photo_zone' && (
        <PhotoZonePropertiesSection element={element as PhotoZoneElement} updateElement={updateElement} pushHistory={pushHistory} />
      )}

      {/* Appearance */}
      <AppearanceSection element={element} updateElement={updateElement} pushHistory={pushHistory} />
    </div>
  );
};

// ---------------------------------------------------------------------------
// Sub-sections
// ---------------------------------------------------------------------------

interface UpdateFn {
  (id: string, updates: Partial<TemplateElement>): void;
}

interface SectionProps {
  element: TemplateElement;
  updateElement: UpdateFn;
  pushHistory: (label: string) => void;
}

// --- Transform ---

const TransformSection: React.FC<SectionProps> = ({ element, updateElement, pushHistory }) => {
  const update = (field: string, value: number) => {
    updateElement(element.id, { [field]: value } as Partial<TemplateElement>);
  };

  return (
    <div style={styles.section}>
      <div style={styles.sectionTitle}>Transform</div>
      <div style={styles.grid2}>
        <NumberField label="X" value={element.x} onChange={(v) => update('x', v)} onBlur={() => pushHistory('Move')} />
        <NumberField label="Y" value={element.y} onChange={(v) => update('y', v)} onBlur={() => pushHistory('Move')} />
        <NumberField label="W" value={element.width} onChange={(v) => update('width', v)} onBlur={() => pushHistory('Resize')} min={1} />
        <NumberField label="H" value={element.height} onChange={(v) => update('height', v)} onBlur={() => pushHistory('Resize')} min={1} />
        <NumberField label="Rotation" value={element.rotation} onChange={(v) => update('rotation', v)} onBlur={() => pushHistory('Rotate')} />
      </div>
    </div>
  );
};

// --- Text ---

const TextPropertiesSection: React.FC<{
  element: TextElement;
  updateElement: UpdateFn;
  pushHistory: (label: string) => void;
}> = ({ element, updateElement, pushHistory }) => {
  const update = (updates: Partial<TextElement>) => {
    updateElement(element.id, updates as Partial<TemplateElement>);
  };

  return (
    <div style={styles.section}>
      <div style={styles.sectionTitle}>Text</div>

      {/* Content */}
      <textarea
        value={element.content}
        onChange={(e) => update({ content: e.target.value })}
        onBlur={() => pushHistory('Edit text')}
        style={styles.textarea}
        rows={3}
      />

      {/* Font family */}
      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Font</label>
        <input
          type="text"
          value={element.font.family}
          onChange={(e) =>
            update({
              font: { ...element.font, family: e.target.value },
            })
          }
          onBlur={() => pushHistory('Change font')}
          style={styles.textInput}
        />
      </div>

      {/* Font size */}
      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Size</label>
        <input
          type="number"
          value={element.fontSize}
          onChange={(e) => update({ fontSize: parseInt(e.target.value) || 12 })}
          onBlur={() => pushHistory('Change font size')}
          style={styles.numberFieldInput}
          min={1}
          max={999}
        />
      </div>

      {/* Font weight */}
      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Weight</label>
        <select
          value={element.font.weight}
          onChange={(e) =>
            update({
              font: { ...element.font, weight: parseInt(e.target.value) },
            })
          }
          style={styles.select}
        >
          {[100, 200, 300, 400, 500, 600, 700, 800, 900].map((w) => (
            <option key={w} value={w}>
              {w}
            </option>
          ))}
        </select>
      </div>

      {/* Color */}
      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Color</label>
        <input
          type="color"
          value={typeof element.fill === 'string' ? element.fill.slice(0, 7) : '#000000'}
          onChange={(e) => update({ fill: e.target.value + 'FF' })}
          onBlur={() => pushHistory('Change text color')}
          style={styles.colorInput}
        />
      </div>

      {/* Alignment */}
      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Align</label>
        <div style={styles.buttonGroup}>
          {(['left', 'center', 'right'] as const).map((align) => (
            <button
              key={align}
              onClick={() => {
                update({ textAlign: align });
                pushHistory('Change alignment');
              }}
              style={{
                ...styles.groupButton,
                ...(element.textAlign === align ? styles.groupButtonActive : {}),
              }}
            >
              {align === 'left' ? '⬅' : align === 'center' ? '⬌' : '➡'}
            </button>
          ))}
        </div>
      </div>

      {/* Line height */}
      <NumberField
        label="Line Height"
        value={element.lineHeight}
        onChange={(v) => update({ lineHeight: v })}
        onBlur={() => pushHistory('Change line height')}
        step={0.1}
        min={0.5}
        max={5}
      />

      {/* Letter spacing */}
      <NumberField
        label="Spacing"
        value={element.letterSpacing}
        onChange={(v) => update({ letterSpacing: v })}
        onBlur={() => pushHistory('Change letter spacing')}
        step={0.5}
      />

      {/* Decoration */}
      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Style</label>
        <div style={styles.buttonGroup}>
          <button
            onClick={() => {
              update({
                textDecoration: element.textDecoration === 'underline' ? 'none' : 'underline',
              });
              pushHistory('Toggle underline');
            }}
            style={{
              ...styles.groupButton,
              ...(element.textDecoration === 'underline' ? styles.groupButtonActive : {}),
              textDecoration: 'underline',
            }}
          >
            U
          </button>
          <button
            onClick={() => {
              update({
                textDecoration: element.textDecoration === 'line-through' ? 'none' : 'line-through',
              });
              pushHistory('Toggle strikethrough');
            }}
            style={{
              ...styles.groupButton,
              ...(element.textDecoration === 'line-through' ? styles.groupButtonActive : {}),
              textDecoration: 'line-through',
            }}
          >
            S
          </button>
          <button
            onClick={() => {
              update({
                font: {
                  ...element.font,
                  style: element.font.style === 'italic' ? 'normal' : 'italic',
                },
              });
              pushHistory('Toggle italic');
            }}
            style={{
              ...styles.groupButton,
              ...(element.font.style === 'italic' ? styles.groupButtonActive : {}),
              fontStyle: 'italic',
            }}
          >
            I
          </button>
        </div>
      </div>

      {/* Text transform */}
      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Transform</label>
        <select
          value={element.textTransform}
          onChange={(e) => {
            update({ textTransform: e.target.value as TextElement['textTransform'] });
            pushHistory('Change text transform');
          }}
          style={styles.select}
        >
          <option value="none">None</option>
          <option value="uppercase">UPPERCASE</option>
          <option value="lowercase">lowercase</option>
          <option value="capitalize">Capitalize</option>
        </select>
      </div>
    </div>
  );
};

// --- Image ---

const ImagePropertiesSection: React.FC<{
  element: ImageElement;
  updateElement: UpdateFn;
  pushHistory: (label: string) => void;
}> = ({ element, updateElement, pushHistory }) => {
  const update = (updates: Partial<ImageElement>) => {
    updateElement(element.id, updates as Partial<TemplateElement>);
  };

  return (
    <div style={styles.section}>
      <div style={styles.sectionTitle}>Image</div>

      <NumberField
        label="Corner Radius"
        value={element.cornerRadius}
        onChange={(v) => update({ cornerRadius: v })}
        onBlur={() => pushHistory('Change corner radius')}
        min={0}
      />

      {/* Filters */}
      <div style={styles.sectionTitle}>Filters</div>
      <NumberField
        label="Brightness"
        value={element.filters?.brightness ?? 0}
        onChange={(v) =>
          update({ filters: { ...element.filters, brightness: v } })
        }
        onBlur={() => pushHistory('Change brightness')}
        step={0.1}
        min={-1}
        max={1}
      />
      <NumberField
        label="Contrast"
        value={element.filters?.contrast ?? 0}
        onChange={(v) =>
          update({ filters: { ...element.filters, contrast: v } })
        }
        onBlur={() => pushHistory('Change contrast')}
        step={0.1}
        min={-1}
        max={1}
      />
      <NumberField
        label="Saturation"
        value={element.filters?.saturation ?? 0}
        onChange={(v) =>
          update({ filters: { ...element.filters, saturation: v } })
        }
        onBlur={() => pushHistory('Change saturation')}
        step={0.1}
        min={-1}
        max={1}
      />

      <div style={styles.fieldRow}>
        <label style={styles.checkboxLabel}>
          <input
            type="checkbox"
            checked={element.filters?.grayscale ?? false}
            onChange={(e) => {
              update({ filters: { ...element.filters, grayscale: e.target.checked } });
              pushHistory('Toggle grayscale');
            }}
          />
          Grayscale
        </label>
      </div>
    </div>
  );
};

// --- Shape ---

const ShapePropertiesSection: React.FC<{
  element: ShapeElement;
  updateElement: UpdateFn;
  pushHistory: (label: string) => void;
}> = ({ element, updateElement, pushHistory }) => {
  const update = (updates: Partial<ShapeElement>) => {
    updateElement(element.id, updates as Partial<TemplateElement>);
  };

  return (
    <div style={styles.section}>
      <div style={styles.sectionTitle}>Shape</div>

      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Type</label>
        <select
          value={element.shapeKind}
          onChange={(e) => {
            update({ shapeKind: e.target.value as ShapeElement['shapeKind'] });
            pushHistory('Change shape type');
          }}
          style={styles.select}
        >
          <option value="rectangle">Rectangle</option>
          <option value="ellipse">Ellipse</option>
          <option value="triangle">Triangle</option>
          <option value="line">Line</option>
          <option value="polygon">Polygon</option>
          <option value="star">Star</option>
        </select>
      </div>

      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Fill</label>
        <input
          type="color"
          value={typeof element.fill === 'string' ? element.fill.slice(0, 7) : '#4A90D9'}
          onChange={(e) => update({ fill: e.target.value + 'FF' })}
          onBlur={() => pushHistory('Change fill')}
          style={styles.colorInput}
        />
      </div>

      {(element.shapeKind === 'rectangle' || element.shapeKind === 'polygon') && (
        <NumberField
          label="Corner Radius"
          value={element.cornerRadius ?? 0}
          onChange={(v) => update({ cornerRadius: v })}
          onBlur={() => pushHistory('Change corner radius')}
          min={0}
        />
      )}

      {(element.shapeKind === 'polygon' || element.shapeKind === 'star') && (
        <NumberField
          label="Points"
          value={element.points ?? 5}
          onChange={(v) => update({ points: v })}
          onBlur={() => pushHistory('Change points')}
          min={3}
          max={20}
        />
      )}

      {/* Stroke */}
      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Stroke</label>
        <input
          type="color"
          value={element.stroke?.color?.slice(0, 7) ?? '#000000'}
          onChange={(e) =>
            update({
              stroke: {
                color: e.target.value + 'FF',
                width: element.stroke?.width ?? 0,
              },
            })
          }
          onBlur={() => pushHistory('Change stroke color')}
          style={styles.colorInput}
        />
      </div>
      <NumberField
        label="Stroke Width"
        value={element.stroke?.width ?? 0}
        onChange={(v) =>
          update({
            stroke: {
              color: element.stroke?.color ?? '#000000FF',
              width: v,
            },
          })
        }
        onBlur={() => pushHistory('Change stroke width')}
        min={0}
      />
    </div>
  );
};

// --- Photo Zone ---

const PhotoZonePropertiesSection: React.FC<{
  element: PhotoZoneElement;
  updateElement: UpdateFn;
  pushHistory: (label: string) => void;
}> = ({ element, updateElement, pushHistory }) => {
  const update = (updates: Partial<PhotoZoneElement>) => {
    updateElement(element.id, updates as Partial<TemplateElement>);
  };

  return (
    <div style={styles.section}>
      <div style={styles.sectionTitle}>Photo Zone</div>

      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Label</label>
        <input
          type="text"
          value={element.label}
          onChange={(e) => update({ label: e.target.value })}
          onBlur={() => pushHistory('Change label')}
          style={styles.textInput}
        />
      </div>

      <NumberField
        label="Capture Index"
        value={element.captureIndex}
        onChange={(v) => update({ captureIndex: v })}
        onBlur={() => pushHistory('Change capture index')}
        min={0}
      />

      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Fill Mode</label>
        <select
          value={element.fillMode}
          onChange={(e) => {
            update({ fillMode: e.target.value as 'cover' | 'contain' });
            pushHistory('Change fill mode');
          }}
          style={styles.select}
        >
          <option value="cover">Cover</option>
          <option value="contain">Contain</option>
        </select>
      </div>

      <NumberField
        label="Corner Radius"
        value={element.cornerRadius}
        onChange={(v) => update({ cornerRadius: v })}
        onBlur={() => pushHistory('Change corner radius')}
        min={0}
      />

      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Aspect Ratio</label>
        <select
          value={element.aspectRatio || ''}
          onChange={(e) => {
            update({ aspectRatio: e.target.value || undefined });
            pushHistory('Change aspect ratio');
          }}
          style={styles.select}
        >
          <option value="">Free</option>
          <option value="1:1">1:1</option>
          <option value="4:3">4:3</option>
          <option value="3:4">3:4</option>
          <option value="16:9">16:9</option>
          <option value="9:16">9:16</option>
        </select>
      </div>

      <div style={styles.infoBox}>
        This area becomes transparent in the exported PNG. The iPad app will
        place the captured photo here.
      </div>
    </div>
  );
};

// --- Background ---

const BackgroundSection: React.FC<{
  background: TemplateBackground;
  setBackground: (bg: TemplateBackground) => void;
  pushHistory: (label: string) => void;
}> = ({ background, setBackground, pushHistory }) => {
  return (
    <div style={styles.section}>
      <div style={styles.sectionTitle}>Background</div>

      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Type</label>
        <select
          value={background.type}
          onChange={(e) => {
            setBackground({ ...background, type: e.target.value as TemplateBackground['type'] });
          }}
          style={styles.select}
        >
          <option value="color">Solid Color</option>
          <option value="gradient">Gradient</option>
          <option value="image">Image</option>
        </select>
      </div>

      {background.type === 'color' && (
        <div style={styles.fieldRow}>
          <label style={styles.fieldLabel}>Color</label>
          <input
            type="color"
            value={background.color?.slice(0, 7) ?? '#FFFFFF'}
            onChange={(e) =>
              setBackground({ ...background, color: e.target.value + 'FF' })
            }
            style={styles.colorInput}
          />
        </div>
      )}

      {background.type === 'image' && (
        <div style={styles.fieldRow}>
          <label style={styles.fieldLabel}>URL</label>
          <input
            type="text"
            value={background.imageUrl || ''}
            onChange={(e) =>
              setBackground({ ...background, imageUrl: e.target.value })
            }
            onBlur={() => pushHistory('Change background image')}
            style={styles.textInput}
            placeholder="https://..."
          />
        </div>
      )}
    </div>
  );
};

// --- Appearance (common to all types) ---

const AppearanceSection: React.FC<SectionProps> = ({ element, updateElement, pushHistory }) => {
  return (
    <div style={styles.section}>
      <div style={styles.sectionTitle}>Appearance</div>

      <NumberField
        label="Opacity"
        value={element.opacity}
        onChange={(v) => updateElement(element.id, { opacity: v } as Partial<TemplateElement>)}
        onBlur={() => pushHistory('Change opacity')}
        step={0.05}
        min={0}
        max={1}
      />

      <div style={styles.fieldRow}>
        <label style={styles.fieldLabel}>Blend</label>
        <select
          value={element.blendMode}
          onChange={(e) => {
            updateElement(element.id, { blendMode: e.target.value } as Partial<TemplateElement>);
            pushHistory('Change blend mode');
          }}
          style={styles.select}
        >
          {[
            'normal', 'multiply', 'screen', 'overlay',
            'darken', 'lighten', 'color-dodge', 'color-burn',
            'soft-light', 'hard-light',
          ].map((mode) => (
            <option key={mode} value={mode}>{mode}</option>
          ))}
        </select>
      </div>
    </div>
  );
};

// --- Common properties for multi-select ---

const CommonPropertiesSection: React.FC<{
  elements: TemplateElement[];
  updateElement: UpdateFn;
  pushHistory: (label: string) => void;
}> = ({ elements, updateElement, pushHistory }) => {
  const updateAll = (updates: Partial<TemplateElement>) => {
    elements.forEach((el) => updateElement(el.id, updates));
  };

  return (
    <div style={styles.section}>
      <div style={styles.sectionTitle}>Common</div>
      <NumberField
        label="Opacity"
        value={elements[0]?.opacity ?? 1}
        onChange={(v) => updateAll({ opacity: v } as Partial<TemplateElement>)}
        onBlur={() => pushHistory('Change opacity')}
        step={0.05}
        min={0}
        max={1}
      />
    </div>
  );
};

// ---------------------------------------------------------------------------
// Shared field components
// ---------------------------------------------------------------------------

interface NumberFieldProps {
  label: string;
  value: number;
  onChange: (value: number) => void;
  onBlur?: () => void;
  min?: number;
  max?: number;
  step?: number;
}

const NumberField: React.FC<NumberFieldProps> = ({
  label,
  value,
  onChange,
  onBlur,
  min,
  max,
  step = 1,
}) => (
  <div style={styles.fieldRow}>
    <label style={styles.fieldLabel}>{label}</label>
    <input
      type="number"
      value={Math.round(value * 100) / 100}
      onChange={(e) => onChange(parseFloat(e.target.value) || 0)}
      onBlur={onBlur}
      style={styles.numberFieldInput}
      min={min}
      max={max}
      step={step}
    />
  </div>
);

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const styles: Record<string, React.CSSProperties> = {
  panel: {
    width: 280,
    backgroundColor: '#fff',
    borderLeft: '1px solid #e0e0e0',
    overflowY: 'auto',
    height: '100%',
  },
  header: {
    padding: '12px 16px',
    fontWeight: 600,
    fontSize: 14,
    borderBottom: '1px solid #e0e0e0',
  },
  section: {
    padding: '12px 16px',
    borderBottom: '1px solid #f0f0f0',
  },
  sectionTitle: {
    fontSize: 11,
    fontWeight: 600,
    textTransform: 'uppercase',
    color: '#888',
    marginBottom: 8,
    letterSpacing: 0.5,
  },
  grid2: {
    display: 'grid',
    gridTemplateColumns: '1fr 1fr',
    gap: 6,
  },
  fieldRow: {
    display: 'flex',
    alignItems: 'center',
    gap: 8,
    marginBottom: 8,
  },
  fieldLabel: {
    fontSize: 12,
    color: '#555',
    minWidth: 70,
    flexShrink: 0,
  },
  textInput: {
    flex: 1,
    fontSize: 12,
    padding: '4px 8px',
    border: '1px solid #ddd',
    borderRadius: 4,
  },
  numberFieldInput: {
    flex: 1,
    fontSize: 12,
    padding: '4px 8px',
    border: '1px solid #ddd',
    borderRadius: 4,
    maxWidth: 80,
  },
  colorInput: {
    width: 32,
    height: 28,
    padding: 0,
    border: '1px solid #ddd',
    borderRadius: 4,
    cursor: 'pointer',
  },
  select: {
    flex: 1,
    fontSize: 12,
    padding: '4px 8px',
    border: '1px solid #ddd',
    borderRadius: 4,
  },
  textarea: {
    width: '100%',
    fontSize: 12,
    padding: '6px 8px',
    border: '1px solid #ddd',
    borderRadius: 4,
    resize: 'vertical',
    fontFamily: 'inherit',
    marginBottom: 8,
  },
  buttonGroup: {
    display: 'flex',
    gap: 2,
  },
  groupButton: {
    width: 28,
    height: 28,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    border: '1px solid #ddd',
    borderRadius: 4,
    background: '#fff',
    cursor: 'pointer',
    fontSize: 12,
  },
  groupButtonActive: {
    backgroundColor: '#e8f0fe',
    borderColor: '#4285f4',
    color: '#4285f4',
  },
  checkboxLabel: {
    display: 'flex',
    alignItems: 'center',
    gap: 6,
    fontSize: 12,
    cursor: 'pointer',
  },
  info: {
    fontSize: 12,
    color: '#666',
    margin: 0,
  },
  infoBox: {
    fontSize: 11,
    color: '#666',
    backgroundColor: '#f8f9fa',
    borderRadius: 4,
    padding: 8,
    marginTop: 8,
    lineHeight: 1.4,
  },
};

export default PropertiesPanel;
