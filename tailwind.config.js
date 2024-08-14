/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./static/**/*.{html,css}",
    "./templates/**/*.{html, css}",
    "./main.odin",
  ],
  theme: {
    extend: {},
  },
  daisyui: {
    darkTheme: "mytheme",
    themes: [
      "pastel",
      {
        mytheme: {
          primary: "#dfae67",
          secondary: "#956d00",
          accent: "#a485dd",
          neutral: "#11121d",
          "base-100": "#11121d",
          info: "#7199ee",
          success: "#95c561",
          warning: "#b26700",
          error: "#ee6d85",
        },
      },
    ],
  },
  plugins: [require("daisyui")],
};
