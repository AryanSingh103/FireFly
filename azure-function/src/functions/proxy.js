const { app } = require('@azure/functions');

const GEMINI_MODEL = process.env.GEMINI_MODEL || 'gemini-flash-latest';

app.http('gemini', {
    methods: ['POST'],
    authLevel: 'function',
    handler: async (request) => {
        const upstream = await fetch(
            `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`,
            {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'x-goog-api-key': process.env.GEMINI_API_KEY,
                },
                body: await request.text(),
            }
        );
        return {
            status: upstream.status,
            headers: { 'Content-Type': 'application/json' },
            body: await upstream.text(),
        };
    },
});

app.http('tts', {
    methods: ['POST'],
    authLevel: 'function',
    handler: async (request) => {
        const { text } = await request.json();
        if (typeof text !== 'string' || text.length === 0 || text.length > 300) {
            return { status: 400, body: 'text must be a string of 1 to 300 characters' };
        }
        const upstream = await fetch(
            `https://api.elevenlabs.io/v1/text-to-speech/${process.env.ELEVENLABS_VOICE_ID}?output_format=mp3_44100_128`,
            {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'xi-api-key': process.env.ELEVENLABS_API_KEY,
                },
                body: JSON.stringify({ text, model_id: 'eleven_flash_v2_5' }),
            }
        );
        return {
            status: upstream.status,
            headers: { 'Content-Type': 'audio/mpeg' },
            body: Buffer.from(await upstream.arrayBuffer()),
        };
    },
});
