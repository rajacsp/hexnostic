import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",
  images: {
    remotePatterns: [
      { protocol: "https", hostname: "avatars.charhub.io" },
      { protocol: "https", hostname: "ct-cards.storage.character-tavern.com" },
      { protocol: "https", hostname: "sv.risuai.xyz" },
      { protocol: "https", hostname: "realm.risuai.net" },
    ],
  },
};

export default nextConfig;
