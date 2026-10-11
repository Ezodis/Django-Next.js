import type { Metadata, Viewport } from "next";
import "./globals.css";
import {AutomaticTranslationProvider} from '../localization/client';
import {getInitialLocalization} from '../localization/server';
import {direction} from '../localization/core.cjs';

export const metadata: Metadata = {
  title: process.env.NEXT_PUBLIC_APP_NAME ?? "App",
  description: process.env.NEXT_PUBLIC_APP_DESCRIPTION ?? "App description",
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  userScalable: false,
  viewportFit: "cover",
};

export default async function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const localization = await getInitialLocalization();
  return (
    <html lang={localization.language} dir={direction(localization.language)}>
      <head />
      <body className="antialiased"><AutomaticTranslationProvider initial={localization}>{children}</AutomaticTranslationProvider></body>
    </html>
  );
}
