/**
 * Asset Service
 *
 * Handles image/font upload to S3 via presigned URLs, and asset CRUD.
 *
 * Architecture:
 *   1. Client requests a presigned upload URL from the backend API
 *   2. Client uploads directly to S3 (no server bandwidth bottleneck)
 *   3. Client notifies API to finalize the asset record
 *   4. Assets are served via CloudFront CDN
 *
 * S3 Bucket Structure:
 *   s3://photobooth-assets/
 *     ├── users/{userId}/
 *     │   ├── images/{assetId}.{ext}
 *     │   ├── fonts/{fontId}.{ext}
 *     │   └── templates/{templateId}.json
 *     ├── shared/
 *     │   ├── stickers/
 *     │   ├── backgrounds/
 *     │   └── template-presets/
 *     └── thumbnails/
 *         └── {assetId}_thumb.webp
 */

import {
  S3Client,
  PutObjectCommand,
  DeleteObjectCommand,
  GetObjectCommand,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { v4 as uuid } from 'uuid';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

export interface AssetServiceConfig {
  /** S3 bucket name */
  bucketName: string;
  /** AWS region */
  region: string;
  /** CloudFront distribution domain (e.g., d1234.cloudfront.net) */
  cdnDomain: string;
  /** Backend API base URL for asset metadata CRUD */
  apiBaseUrl: string;
  /** Current user ID */
  userId: string;
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface UploadResult {
  assetId: string;
  url: string;         // CDN URL
  thumbnailUrl: string;
  s3Key: string;
}

export interface PresignedUploadUrl {
  uploadUrl: string;
  s3Key: string;
  assetId: string;
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

export class AssetService {
  private config: AssetServiceConfig;

  constructor(config: AssetServiceConfig) {
    this.config = config;
  }

  /**
   * Request a presigned upload URL from the backend.
   * The backend generates the presigned URL (keeps AWS credentials server-side).
   */
  async getPresignedUploadUrl(
    fileName: string,
    contentType: string,
    category: 'images' | 'fonts' | 'templates' = 'images',
  ): Promise<PresignedUploadUrl> {
    const response = await fetch(
      `${this.config.apiBaseUrl}/assets/presigned-url`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          fileName,
          contentType,
          category,
          userId: this.config.userId,
        }),
      },
    );

    if (!response.ok) {
      throw new Error(`Failed to get presigned URL: ${response.statusText}`);
    }

    return response.json();
  }

  /**
   * Upload a file to S3 using a presigned URL.
   */
  async uploadFile(
    file: File,
    category: 'images' | 'fonts' | 'templates' = 'images',
  ): Promise<UploadResult> {
    // 1. Get presigned URL from backend
    const { uploadUrl, s3Key, assetId } = await this.getPresignedUploadUrl(
      file.name,
      file.type,
      category,
    );

    // 2. Upload directly to S3
    const uploadResponse = await fetch(uploadUrl, {
      method: 'PUT',
      body: file,
      headers: {
        'Content-Type': file.type,
      },
    });

    if (!uploadResponse.ok) {
      throw new Error(`S3 upload failed: ${uploadResponse.statusText}`);
    }

    // 3. Notify backend to finalize the asset record
    const cdnUrl = `https://${this.config.cdnDomain}/${s3Key}`;
    const thumbnailUrl = `https://${this.config.cdnDomain}/thumbnails/${assetId}_thumb.webp`;

    await this.finalizeUpload(assetId, {
      url: cdnUrl,
      thumbnailUrl,
      s3Key,
      fileName: file.name,
      contentType: file.type,
      fileSize: file.size,
      category,
    });

    return {
      assetId,
      url: cdnUrl,
      thumbnailUrl,
      s3Key,
    };
  }

  /**
   * Notify the backend that an upload completed successfully.
   * The backend will trigger thumbnail generation (e.g., via Lambda).
   */
  private async finalizeUpload(
    assetId: string,
    metadata: Record<string, unknown>,
  ): Promise<void> {
    const response = await fetch(
      `${this.config.apiBaseUrl}/assets/${assetId}/finalize`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(metadata),
      },
    );

    if (!response.ok) {
      throw new Error(`Failed to finalize upload: ${response.statusText}`);
    }
  }

  /**
   * Delete an asset (S3 object + database record).
   */
  async deleteAsset(assetId: string): Promise<void> {
    const response = await fetch(
      `${this.config.apiBaseUrl}/assets/${assetId}`,
      {
        method: 'DELETE',
      },
    );

    if (!response.ok) {
      throw new Error(`Failed to delete asset: ${response.statusText}`);
    }
  }

  /**
   * List assets for the current user.
   */
  async listAssets(
    category?: string,
    page: number = 1,
    limit: number = 50,
  ): Promise<{ assets: unknown[]; total: number }> {
    const params = new URLSearchParams({
      userId: this.config.userId,
      page: String(page),
      limit: String(limit),
    });
    if (category) params.set('category', category);

    const response = await fetch(
      `${this.config.apiBaseUrl}/assets?${params}`,
    );

    if (!response.ok) {
      throw new Error(`Failed to list assets: ${response.statusText}`);
    }

    return response.json();
  }

  /**
   * Save a template JSON to S3.
   */
  async saveTemplate(
    templateId: string,
    templateJson: unknown,
  ): Promise<string> {
    const file = new File(
      [JSON.stringify(templateJson, null, 2)],
      `${templateId}.json`,
      { type: 'application/json' },
    );

    const result = await this.uploadFile(file, 'templates');
    return result.url;
  }

  /**
   * Load a template JSON from its URL.
   */
  async loadTemplate(url: string): Promise<unknown> {
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`Failed to load template: ${response.statusText}`);
    }
    return response.json();
  }
}

// ---------------------------------------------------------------------------
// Backend API Reference (Express.js example for the server-side)
// ---------------------------------------------------------------------------

/**
 * Server-side presigned URL generation (for reference):
 *
 * ```typescript
 * // server/routes/assets.ts
 *
 * import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';
 * import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
 * import { v4 as uuid } from 'uuid';
 *
 * const s3 = new S3Client({ region: process.env.AWS_REGION });
 * const BUCKET = process.env.S3_BUCKET;
 *
 * app.post('/api/assets/presigned-url', async (req, res) => {
 *   const { fileName, contentType, category, userId } = req.body;
 *   const assetId = uuid();
 *   const ext = fileName.split('.').pop();
 *   const s3Key = `users/${userId}/${category}/${assetId}.${ext}`;
 *
 *   const command = new PutObjectCommand({
 *     Bucket: BUCKET,
 *     Key: s3Key,
 *     ContentType: contentType,
 *   });
 *
 *   const uploadUrl = await getSignedUrl(s3, command, { expiresIn: 3600 });
 *
 *   res.json({ uploadUrl, s3Key, assetId });
 * });
 *
 * app.post('/api/assets/:id/finalize', async (req, res) => {
 *   // Create asset record in database
 *   // Trigger Lambda for thumbnail generation
 *   // Return success
 * });
 * ```
 */
