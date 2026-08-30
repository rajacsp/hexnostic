import { POST as adaptCharacterCard } from "../import-card/route";

export const runtime = "nodejs";
export const maxDuration = 120;

export async function POST(request: Request) {
  return adaptCharacterCard(request);
}
