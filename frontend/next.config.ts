import type { NextConfig } from "next";

const DJANGO_ORIGIN = process.env.DJANGO_ORIGIN || "http://127.0.0.1:8000";

const nextConfig: NextConfig = {
  devIndicators: false,
  async rewrites() {
    return [{ source: "/api/:path*", destination: `${DJANGO_ORIGIN}/api/:path*` }];
  },
};

export default nextConfig;
