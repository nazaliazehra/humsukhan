// supabase/functions/generate-insights/index.ts
//
// Supabase Edge Function — proxies Gemini AI requests from the Flutter client.
// The GEMINI_API_KEY secret lives only in Supabase server-side secrets and
// is never shipped inside the mobile binary.
//
// Deploy:
//   supabase secrets set GEMINI_API_KEY=<your-key>
//   supabase functions deploy generate-insights
//
// Invoke from Flutter:
//   Supabase.instance.client.functions.invoke('generate-insights', body: {...})

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// ── CORS headers (Supabase also sets these, but we include for OPTIONS) ─────
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

// Supported transcript languages.  The client may send any of these; the
// prompt instructs Gemini to produce output in the same language.
const SUPPORTED_LANGUAGES = ["English", "Urdu", "Hindi", "Roman Urdu"];

// ── HTTP helpers ─────────────────────────────────────────────────────────────
function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function errorResponse(error: string, status: number, detail?: string) {
  return jsonResponse({ error, ...(detail ? { detail } : {}) }, status);
}

// ── Main handler ─────────────────────────────────────────────────────────────
Deno.serve(async (req: Request) => {
  // Preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return errorResponse("Method not allowed", 405);
  }

  // ── 1. Authenticate — require a valid Supabase JWT ─────────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return errorResponse("Missing authentication token", 401);
  }

  try {
    const supabaseAdmin = createSupabaseAdmin();
    const {
      data: { user },
      error: authError,
    } = await supabaseAdmin.auth.getUser(authHeader.replace("Bearer ", ""));

    if (authError || !user) {
      return errorResponse("Invalid or expired authentication token", 401);
    }

    // ── 2. Parse and validate request body ───────────────────────────────────
    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return errorResponse("Invalid JSON in request body", 400);
    }

    const transcript = body.transcript as string;
    const sessionTitle = body.sessionTitle as string;
    const sessionType = body.sessionType as string;
    const language = (body.language as string) || "English";

    if (!transcript || typeof transcript !== "string") {
      return errorResponse("transcript is required and must be a string", 400);
    }
    if (transcript.trim().length === 0) {
      return errorResponse("transcript must not be empty", 400);
    }
    if (
      !sessionType ||
      !["meeting", "lecture", "class"].includes(sessionType)
    ) {
      return errorResponse(
        "sessionType must be one of: meeting, lecture, class",
        400,
      );
    }
    if (typeof language !== "string" || language.trim().length === 0) {
      return errorResponse("language must be a non-empty string", 400);
    }

    // ── 3. Read server-side secret ──────────────────────────────────────────
    const geminiApiKey = Deno.env.get("GEMINI_API_KEY");
    if (!geminiApiKey) {
      console.error("GEMINI_API_KEY secret is not configured");
      return errorResponse("AI service is not configured", 503);
    }

    // ── 4. Call Gemini API ───────────────────────────────────────────────────
    const prompt = buildInsightPrompt(transcript, sessionTitle, sessionType, language);
    const geminiUrl =
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${geminiApiKey}`;

    const geminiResponse = await fetch(geminiUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: {
          temperature: 0.3,
          maxOutputTokens: 2048,
        },
      }),
    });

    if (!geminiResponse.ok) {
      // Log upstream error for ops; return sanitised message to client.
      const errorText = await geminiResponse.text();
      console.error(
        `Gemini API error (${geminiResponse.status}): ${errorText}`,
      );
      return errorResponse("AI service returned an error", 502);
    }

    const geminiData = await geminiResponse.json();

    // ── 5. Extract generated text ───────────────────────────────────────────
    const candidates = geminiData?.candidates;
    if (!Array.isArray(candidates) || candidates.length === 0) {
      console.error("Gemini returned no candidates");
      return errorResponse("AI service returned an empty response", 502);
    }

    const parts = candidates[0]?.content?.parts;
    if (!Array.isArray(parts) || parts.length === 0) {
      console.error("Gemini candidate has no content parts");
      return errorResponse("AI service returned a malformed response", 502);
    }

    const rawText = parts[0].text as string;

    // ── 6. Server-side validation of the structured JSON output ────────────
    const validated = validateInsightJson(rawText);
    if (!validated) {
      console.error("Gemini returned invalid insight JSON:", rawText.substring(0, 300));
      return errorResponse("AI service returned unparseable insight data", 502);
    }

    return jsonResponse({ text: JSON.stringify(validated), language });
  } catch (err) {
    console.error("generate-insights error:", err);
    return errorResponse("Internal server error", 500);
  }
});

// ── Helpers ──────────────────────────────────────────────────────────────────

function createSupabaseAdmin() {
  // Uses service_role key — only available server-side in the Edge Runtime.
  // Never ship this key to the Flutter client.
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
}

/**
 * Validate and normalise the raw AI text into a well-formed insight object.
 * Returns `null` if the text cannot be parsed as the expected JSON schema.
 */
function validateInsightJson(
  rawText: string,
): Record<string, unknown> | null {
  try {
    // Strip markdown code fences if present.
    let cleaned = rawText.trim();
    if (cleaned.startsWith("```")) {
      cleaned = cleaned.replace(/^```\w*\n?/, "");
      cleaned = cleaned.replace(/\n?```$/, "");
    }

    const parsed = JSON.parse(cleaned);
    if (typeof parsed !== "object" || parsed === null) return null;

    return {
      summary: typeof parsed.summary === "string" ? parsed.summary : "",
      vocabulary: toStringArray(parsed.vocabulary),
      themes: toStringArray(parsed.themes),
      actionItems: toStringArray(parsed.actionItems),
      deadlines: toStringArray(parsed.deadlines),
      mentionedPeople: toStringArray(parsed.mentionedPeople),
    };
  } catch {
    return null;
  }
}

/** Coerce a value to a string array, dropping non-string elements. */
function toStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((v): v is string => typeof v === "string");
}

/** Build the language-aware analysis prompt for Gemini. */
function buildInsightPrompt(
  transcript: string,
  title: string,
  type: string,
  language: string,
): string {
  // Build a language instruction only when the language is known.
  const isSupported = SUPPORTED_LANGUAGES.includes(language);
  const langInstruction = isSupported
    ? `\n- Produce ALL output values (summary, vocabulary, themes, action items, deadlines, people) in the "${language}" language. Preserve the original script (e.g. Urdu uses Arabic script, Hindi uses Devanagari). Do not transliterate.`
    : `\n- The transcript language is "${language}". Produce output values in the same language and script as the transcript. Do not transliterate.`;

  return `You are an AI assistant analyzing a ${type} transcript titled "${title}".

The transcript language is: ${language}.
${langInstruction}

Analyze the following transcript and return a JSON object with these fields:
- "summary": A concise 2-3 sentence summary that captures the KEY DECISIONS and OUTCOMES of the session. Do NOT simply repeat the first few sentences of the transcript.
- "vocabulary": An array of 5-8 important domain-specific terms, jargon, or technical words used
- "themes": An array of 3-5 main themes or topics discussed
- "actionItems": An array of 3-7 concrete action items or tasks that were agreed upon or assigned
- "deadlines": An array of any deadlines, dates, or time-sensitive items mentioned
- "mentionedPeople": An array of people mentioned BY NAME in the transcript content. Do NOT include generic speaker labels such as "Speaker 1", "Speaker 2", etc.

Important rules:
- Return ONLY valid JSON, no markdown or extra text
- If a field has no data, return an empty array [] (or empty string "" for summary)
- Base everything strictly on the transcript content
- Do not fabricate information that is not present in the transcript
- Do not include speaker identification labels as mentioned people

Transcript:
${transcript}`;
}
