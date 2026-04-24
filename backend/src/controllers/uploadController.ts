import { Request, Response } from 'express';
import { PutObjectCommand } from '@aws-sdk/client-s3';
import s3Client from '../config/s3.js';
import { logger } from '../utils/logger.js';
import crypto from 'crypto';

export const uploadMedia = async (req: Request, res: Response) => {
  try {
    if (!req.file) {
      return res.status(400).json({ error: 'No file uploaded' });
    }

    const fileExtension = req.file.originalname.split('.').pop();
    const fileName = `farmle-messages/${crypto.randomUUID()}.${fileExtension}`;
    
    const uploadParams = {
      Bucket: process.env.AWS_S3_BUCKET!,
      Key: fileName,
      Body: req.file.buffer,
      ContentType: req.file.mimetype,
    };

    await s3Client.send(new PutObjectCommand(uploadParams));
    
    const fileUrl = `https://${process.env.AWS_S3_BUCKET}.s3.${process.env.AWS_REGION}.amazonaws.com/${fileName}`;

    res.json({
      success: true,
      url: fileUrl,
      resource_type: req.file.mimetype.startsWith('image/') ? 'image' : 'video'
    });

  } catch (error) {
    logger.error('S3 upload error:', error);
    res.status(500).json({ error: 'Upload failed' });
  }
};
