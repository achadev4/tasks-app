import { z } from "zod";

export const taskSchema = z.object({
  id: z.string().uuid(),
  userId: z.string().min(1),
  title: z.string().min(1).max(500),
  completed: z.boolean(),
  dueDate: z.string().nullable(),
  category: z.string().max(200).nullable(),
  color: z.string().max(32).nullable(),
  createdAt: z.string(),
  updatedAt: z.string(),
});

export type Task = z.infer<typeof taskSchema>;

export const createTaskBodySchema = z.object({
  title: z.string().min(1).max(500),
  dueDate: z
    .union([z.string().regex(/^\d{4}-\d{2}-\d{2}$/), z.string().datetime()])
    .nullable()
    .optional(),
  category: z.string().max(200).nullable().optional(),
  color: z.string().max(32).nullable().optional(),
});

export const patchTaskBodySchema = z.object({
  title: z.string().min(1).max(500).optional(),
  completed: z.boolean().optional(),
  dueDate: z
    .union([z.string().regex(/^\d{4}-\d{2}-\d{2}$/), z.string().datetime(), z.null()])
    .optional(),
  category: z.string().max(200).nullable().optional(),
  color: z.string().max(32).nullable().optional(),
});

export type CreateTaskBody = z.infer<typeof createTaskBodySchema>;
export type PatchTaskBody = z.infer<typeof patchTaskBodySchema>;

export const taskAttachmentSchema = z.object({
  id: z.string().uuid(),
  taskId: z.string().uuid(),
  fileName: z.string(),
  contentType: z.string().nullable(),
  sizeBytes: z.number().int().nonnegative(),
  blobPath: z.string(),
  createdAt: z.string().datetime(),
});

export type TaskAttachment = z.infer<typeof taskAttachmentSchema>;
