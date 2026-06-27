const express = require('express');
const fs = require('fs');
const path = require('path');
const { LuauFactory } = require('luau-web');

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

const PORT = process.env.PORT || 3000;
const luauFactory = new LuauFactory();
const luauCode = fs.readFileSync(path.join(__dirname, 'deobfuscator.lua'), 'utf8');

app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.post('/deobfuscate', async (req, res) => {
    const targetCode = req.body.code;
    if (!targetCode) {
        return res.status(400).json({ error: 'No code provided' });
    }

    try {
        const luau = await luauFactory.createEngine();
        luau.global.set('target_code', targetCode);
        
        const executionScript = `
            ${luauCode}
            return deobfuscate(target_code)
        `;

        const result = await luau.doString(executionScript);
        res.json({ deobfuscated_code: result });
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

app.listen(PORT, '0.0.0.0', () => {
    console.log(`Server running on port ${PORT}`);
});
