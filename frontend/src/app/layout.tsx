import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Neo4j Movies",
  description: "Ask questions about the Neo4j movie graph and see the result drawn with d3",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
