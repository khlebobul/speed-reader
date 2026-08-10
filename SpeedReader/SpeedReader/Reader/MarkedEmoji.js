// marked-emoji v2.0.3 (MIT) + curated GitHub-style shortcode -> unicode map.
// Bundled into a single resource for SpeedReader. After load:
//   - window.markedEmoji.markedEmoji is the extension factory
//   - window.__rsvpEmojiMap is the {shortcode: unicode} map
//
// Curated list of 124 most common shortcodes (faces, hands, hearts,
// dev/work, misc) — small bundle, covers the practical 80%. Less common shortcodes
// (`:tropical_fish:`, `:badminton_racquet_and_shuttlecock:` etc.) stay as literal
// `:name:` text in the preview; users can paste real Unicode emoji directly and
// they'll be rendered + read by RSVP automatically (no shortcode required).
//
// To extend: edit the curated KEYS list in the bundling script described in
// docs/skills/documents/markdown-support.md and regenerate.
// To pick up newer Unicode emoji for existing shortcodes: re-pull emoji-name-map
// datasource from npm and re-run the bundling script.

(function (global, factory) {
  typeof exports === 'object' && typeof module !== 'undefined' ? factory(exports) :
  typeof define === 'function' && define.amd ? define(['exports'], factory) :
  (global = typeof globalThis !== 'undefined' ? globalThis : global || self, factory(global.markedEmoji = {}));
})(this, (function (exports) { 'use strict';

  const defaultOptions = {
    // emojis: {}, required
    renderer: undefined,
  };

  function markedEmoji(options) {
    options = {
      ...defaultOptions,
      ...options,
    };

    if (!options.emojis) {
      throw new Error('Must provide emojis to markedEmoji');
    }

    const emojiNames = Object.keys(options.emojis).map(e => e.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|');
    const emojiRegex = new RegExp(`:(${emojiNames}):`);
    const tokenizerRule = new RegExp(`^${emojiRegex.source}`);

    return {
      extensions: [{
        name: 'emoji',
        level: 'inline',
        start(src) { return src.match(emojiRegex)?.index; },
        tokenizer(src, tokens) {
          const match = tokenizerRule.exec(src);
          if (!match) {
            return;
          }

          const name = match[1];
          const emoji = options.emojis[name];

          if (!emoji) {
            return;
          }

          return {
            type: 'emoji',
            raw: match[0],
            name,
            emoji,
          };
        },
        renderer(token) {
          if (options.renderer) {
            return options.renderer(token);
          }

          return `<img alt="${token.name}" src="${token.emoji}" class="marked-emoji-img">`;
        },
      }],
    };
  }

  exports.markedEmoji = markedEmoji;

}));

window.__rsvpEmojiMap = {"+1": "👍", "-1": "👎", "100": "💯", "angry": "😠", "astonished": "😲", "beer": "🍺", "blush": "😊", "book": "📖", "books": "📚", "boom": "💥", "broken_heart": "💔", "bug": "🐛", "bulb": "💡", "cake": "🍰", "calendar": "📆", "cat": "🐱", "clap": "👏", "clipboard": "📋", "coffee": "☕", "computer": "💻", "cry": "😢", "disappointed": "😞", "dog": "🐶", "email": "✉️", "exclamation": "❗", "expressionless": "😑", "eyes": "👀", "fire": "🔥", "fist": "✊", "flushed": "😳", "gear": "⚙️", "ghost": "👻", "grin": "😁", "hammer": "🔨", "handshake": "🤝", "hash": "#️⃣", "hear_no_evil": "🙉", "heart": "❤️", "heart_eyes": "😍", "heart_eyes_cat": "😻", "heavy_check_mark": "✔️", "hourglass": "⌛", "hushed": "😯", "innocent": "😇", "iphone": "📱", "joy": "😂", "kissing": "😗", "kissing_heart": "😘", "laughing": "😆", "mask": "😷", "memo": "📝", "metal": "🤘", "moon": "🌔", "muscle": "💪", "nerd_face": "🤓", "neutral_face": "😐", "no_entry": "⛔", "no_mouth": "😶", "ok_hand": "👌", "open_mouth": "😮", "partying_face": "🥳", "pencil": "✏️", "pencil2": "✏️", "pensive": "😔", "pleading_face": "🥺", "point_down": "👇", "point_left": "👈", "point_right": "👉", "point_up": "☝️", "poop": "💩", "pray": "🙏", "question": "❓", "rage": "😡", "rainbow": "🌈", "raised_hands": "🙌", "relaxed": "☺️", "robot": "🤖", "robot_face": "🤖", "rocket": "🚀", "rofl": "🤣", "rolling_on_the_floor_laughing": "🤣", "scream": "😱", "see_no_evil": "🙈", "skull": "💀", "sleeping": "😴", "sleepy": "😪", "slightly_smiling_face": "🙂", "smile": "😄", "smiley": "😃", "smirk": "😏", "sob": "😭", "sparkles": "✨", "sparkling_heart": "💖", "speak_no_evil": "🙊", "star": "⭐", "star-struck": "🤩", "star2": "🌟", "star_struck": "🤩", "stuck_out_tongue": "😛", "sunglasses": "😎", "sunny": "☀️", "sweat_smile": "😅", "tada": "🎉", "the_horns": "🤘", "thinking": "🤔", "thinking_face": "🤔", "thumbsdown": "👎", "thumbsup": "👍", "tired_face": "😫", "tongue": "👅", "two_hearts": "💕", "unamused": "😒", "upside_down_face": "🙃", "v": "✌️", "warning": "⚠️", "wave": "👋", "weary": "😩", "white_check_mark": "✅", "wink": "😉", "worried": "😟", "wrench": "🔧", "x": "❌", "yum": "😋", "zap": "⚡"};
