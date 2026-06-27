# holy vibecoded
import asyncio
import os
from io import BytesIO

import discord
from discord.ext import commands
from dotenv import load_dotenv
from playwright.async_api import async_playwright

load_dotenv()
TOKEN = os.getenv("DISCORD_TOKEN")

intents = discord.Intents.default()
intents.message_content = True

bot = commands.Bot(command_prefix=".", intents=intents)


class CodeView(discord.ui.View):
    def __init__(self, code: str):
        super().__init__(timeout=None)
        self.code = code
        self.current_format = "triple"

    @discord.ui.button(label="💻 PC", style=discord.ButtonStyle.primary)
    async def pc_button(self, interaction: discord.Interaction, button: discord.ui.Button):
        if self.current_format != "triple":
            # Build a fresh embed to avoid API caching/stale object issues
            old_embed = interaction.message.embeds[0]
            new_embed = discord.Embed(
                title=old_embed.title,
                description=f"```lua\n{self.code}\n```",
                color=old_embed.color,
            )
            self.current_format = "triple"
            await interaction.response.edit_message(embed=new_embed, view=self)
        else:
            await interaction.response.defer()

    @discord.ui.button(label="📱 Mobile", style=discord.ButtonStyle.secondary)
    async def mobile_button(self, interaction: discord.Interaction, button: discord.ui.Button):
        if self.current_format != "single":
            old_embed = interaction.message.embeds[0]
            new_embed = discord.Embed(
                title=old_embed.title,
                description=f"`lua\n{self.code}\n`",
                color=old_embed.color,
            )
            self.current_format = "single"
            await interaction.response.edit_message(embed=new_embed, view=self)
        else:
            await interaction.response.defer()


@bot.event
async def on_ready():
    print(f"Logged in as {bot.user}")


@bot.command(name="help")
async def help_command(ctx: commands.Context):
    embed = discord.Embed(
        title="🌙 MoonSec V3 Deobfuscation Bot",
        description="Automates deobfuscation using the web tool at [serverside.neocities.org](https://serverside.neocities.org/decrypter)",
        color=discord.Color.blue(),
    )
    embed.add_field(
        name="`.deobf`",
        value="Attach a `.lua` or `.txt` file containing obfuscated MoonSec V3 code and the bot will return the clean, reconstructed script.",
        inline=False,
    )
    embed.add_field(name="`.help`", value="Shows this help menu.", inline=False)
    embed.set_footer(text="Made with Playwright & discord.py")
    await ctx.send(embed=embed)


@bot.command(name="deobf")
async def deobf_command(ctx: commands.Context):
    clean_code = ""

    if not ctx.message.attachments:
        await ctx.send("❌ Please attach a `.lua` or `.txt` file with the `.deobf` command.")
        return

    attachment = ctx.message.attachments[0]
    if not attachment.filename.lower().endswith((".lua", ".txt")):
        await ctx.send("❌ Invalid file type. Only `.lua` and `.txt` files are accepted.")
        return

    try:
        file_bytes = await attachment.read()
        obfuscated_code = file_bytes.decode("utf-8")
    except Exception as e:
        await ctx.send(f"❌ Failed to read the attachment: {e}")
        return

    async with ctx.typing():
        try:
            async with async_playwright() as p:
                browser = await p.chromium.launch(headless=True)
                page = await browser.new_page()
                await page.goto("https://serverside.neocities.org/decrypter", wait_until="networkidle")

                textarea = page.locator('textarea[placeholder="Paste MoonSec V3 obfuscated Lua code here..."]')
                await textarea.wait_for(state="visible")
                await textarea.fill(obfuscated_code)

                await page.click('text=🧩 Reconstruct Bytecode')
                await asyncio.sleep(2)

                await page.click('text=🔄 Rebuild Original Logic')
                await asyncio.sleep(2)

                await page.click('text=🔍 Format Final Code')
                await asyncio.sleep(6)

                clean_code = await page.evaluate('''() => {
                    let outputEl = document.querySelector('#reconstructed-code, .output, #output');
                    if (outputEl && outputEl.innerText) {
                        let text = outputEl.innerText.trim();
                        if (text && !text.includes('Reconstructed code will appear here') && !text.includes('Paste MoonSec V3')) {
                            return text;
                        }
                    }
                    const textareas = document.querySelectorAll('textarea');
                    for (const ta of textareas) {
                        if (ta.placeholder !== 'Paste MoonSec V3 obfuscated Lua code here...' && ta.value) {
                            let text = ta.value.trim();
                            if (text && !text.includes('Reconstructed code will appear here') && !text.includes('Paste MoonSec V3')) {
                                return text;
                            }
                        }
                    }
                    const headers = document.querySelectorAll('h2');
                    for (const h of headers) {
                        if (h.textContent.includes('🔓 RECONSTRUCTED CODE')) {
                            let node = h.nextElementSibling;
                            while (node) {
                                if (node.nodeType === 1) {
                                    const text = (node.innerText || node.textContent || '').trim();
                                    if (text !== '' && !text.includes('Reconstructed code will appear here') && !text.includes('Paste MoonSec V3')) {
                                        return text;
                                    }
                                }
                                node = node.nextElementSibling;
                            }
                        }
                    }
                    return '';
                }''')

                await browser.close()

        except Exception as e:
            await ctx.send(f"❌ An error occurred during deobfuscation: {e}")
            return

    if not clean_code or "Reconstructed code will appear here" in clean_code or "Paste MoonSec V3 obfuscated Lua code here" in clean_code:
        await ctx.send("❌ Deobfuscation completed but the site returned a placeholder or empty output. It may have failed to process the code.")
        return

    if len(clean_code) <= 1950:
        embed = discord.Embed(
            title="✅ Deobfuscated Code",
            description=f"```lua\n{clean_code}\n```",
            color=discord.Color.green(),
        )
        view = CodeView(clean_code)
        await ctx.send(embed=embed, view=view)
    else:
        lua_file = discord.File(BytesIO(clean_code.encode("utf-8")), filename="deobfuscated.lua")
        txt_file = discord.File(BytesIO(clean_code.encode("utf-8")), filename="deobfuscated.txt")
        await ctx.send(
            content=f"📁 The reconstructed script is too long for an embed. Here are the `.lua` and `.txt` files.\n🔗 Original tool: https://serverside.neocities.org/decrypter",
            files=[lua_file, txt_file],
        )


if __name__ == "__main__":
    bot.run(TOKEN)
