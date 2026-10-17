// Shown by GET /health. Vercel sets VERCEL_GIT_COMMIT_SHA on each deploy.
export const VERSION = `0.1.0${process.env.VERCEL_GIT_COMMIT_SHA ? '+' + process.env.VERCEL_GIT_COMMIT_SHA.slice(0, 7) : ''}`;
