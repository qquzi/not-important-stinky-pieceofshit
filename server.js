const express = require('express');
const fs = require('fs');
const path = require('path');
const { LuaFactory } = require('wasmoon');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;
const luaFactory = new LuaFactory();
const luaCode = fs.readFileSync('deobfuscator.lua', 'utf8');

app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

app.get('/banner.png', (req, res) => {
    res.sendFile(path.join(__dirname, 'banner.png'));
});

app.post('/deobfuscate', async (req, res) => {
    const targetCode = req.body.code;
    if (!targetCode) {
        return res.status(400).json({ error: 'No code provided' });
    }

    try {
        const lua = await luaFactory.createEngine();
        lua.global.set('target_code', targetCode);
        
        const executionScript = `
            ${luaCode}
            return deobfuscate(target_code)
        `;

        const result = await lua.doString(executionScript);
        res.json({ deobfuscated_code: result });
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});
