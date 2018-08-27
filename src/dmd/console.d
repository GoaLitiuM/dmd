/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 1999-2018 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/console.d, _console.d)
 * Documentation:  https://dlang.org/phobos/dmd_console.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/console.d
 */

/********************************************
 * Control the various text mode attributes, such as color, when writing text
 * to the console.
 */

module dmd.console;

import core.stdc.stdio;
extern (C) int isatty(int);


enum Color : int
{
    black         = 0,
    red           = 1,
    green         = 2,
    blue          = 4,
    yellow        = red | green,
    magenta       = red | blue,
    cyan          = green | blue,
    lightGray     = red | green | blue,
    bright        = 8,
    darkGray      = bright | black,
    brightRed     = bright | red,
    brightGreen   = bright | green,
    brightBlue    = bright | blue,
    brightYellow  = bright | yellow,
    brightMagenta = bright | magenta,
    brightCyan    = bright | cyan,
    white         = bright | lightGray,
}

version (Posix)
{
    import core.sys.posix.unistd;
}

interface Console
{
    @property FILE* fp();

    static Console create(FILE* fp, bool forceColors)
    {
        version (Posix)
        {
            return AnsiConsole.create(fp, forceColors);
        }
        else version (Windows)
        {
            Console c = AnsiConsole.create(fp, forceColors);
            if (!c)
                c = WindowsConsole.create(fp, forceColors);
            return c;
        }
        else
            return null;
    }

    void setColorBright(bool bright);
    void setColor(Color color);
    void resetColor();
}

version (Windows)
{
    import core.sys.windows.windows;
    import core.sys.windows.wincon;

    private HANDLE getConsoleHandle(FILE* fp)
    {
        if (fp == stdout)
            return GetStdHandle(STD_OUTPUT_HANDLE);
        else if (fp == stderr)
            return GetStdHandle(STD_ERROR_HANDLE);
        return null;
    }

    bool tryEnableConsoleAnsiCodes(HANDLE con)
    {
        DWORD mode;
        if (!GetConsoleMode(con, &mode))
            return false;

        // pending change druntime#2285
        static if (!is(typeof(ENABLE_VIRTUAL_TERMINAL_PROCESSING)))
            enum ENABLE_VIRTUAL_TERMINAL_PROCESSING = 4;

        if (mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING)
            return true;

        // SetConsoleMode fails when Windows does not support ANSI codes
        if (!SetConsoleMode(con, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING))
            return false;

        return true;
    }

    class WindowsConsole : Console
    {
      private:
        CONSOLE_SCREEN_BUFFER_INFO sbi;
        HANDLE handle;
        FILE* _fp;

      public:
        @property FILE* fp() { return _fp; }

        /*********************************
         * Create an instance of Console connected to stream fp.
         * Params:
         *      fp = io stream
         * Returns:
         *      pointer to created Console
         *      null if failed
         */
        static WindowsConsole create(FILE* fp, bool forceColors)
        {
            /* Determine if stream fp is a console
             */
            version (CRuntime_DigitalMars)
            {
                if (!forceColors && !isatty(fp._file))
                    return null;
            }
            else version (CRuntime_Microsoft)
            {
                if (!forceColors && !isatty(fileno(fp)))
                    return null;
            }
            else
                return null;

            HANDLE con = getConsoleHandle(fp);
            if (!con)
                return null;

            CONSOLE_SCREEN_BUFFER_INFO sbi;
            if (GetConsoleScreenBufferInfo(con, &sbi) == 0) // get initial state of console
                return null;

            auto c = new WindowsConsole();
            c._fp = fp;
            c.handle = con;
            c.sbi = sbi;
            return c;
        }

        /*******************
         * Turn on/off intensity.
         * Params:
         *      bright = turn it on
         */
        void setColorBright(bool bright)
        {
            SetConsoleTextAttribute(handle, sbi.wAttributes | (bright ? FOREGROUND_INTENSITY : 0));
        }

        /***************************
         * Set color and intensity.
         * Params:
         *      color = the color
         */
        void setColor(Color color)
        {
            enum FOREGROUND_WHITE = FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_BLUE;
            WORD attr = sbi.wAttributes;
            attr = (attr & ~(FOREGROUND_WHITE | FOREGROUND_INTENSITY)) |
                   ((color & Color.red)    ? FOREGROUND_RED   : 0) |
                   ((color & Color.green)  ? FOREGROUND_GREEN : 0) |
                   ((color & Color.blue)   ? FOREGROUND_BLUE  : 0) |
                   ((color & Color.bright) ? FOREGROUND_INTENSITY : 0);
            SetConsoleTextAttribute(handle, attr);
        }

        /******************
         * Reset console attributes to what they were
         * when create() was called.
         */
        void resetColor()
        {
            SetConsoleTextAttribute(handle, sbi.wAttributes);
        }
    }
}

/* The ANSI escape codes are used.
 * https://en.wikipedia.org/wiki/ANSI_escape_code
 * Foreground colors: 30..37
 * Background colors: 40..47
 * Attributes:
 *  0: reset all attributes
 *  1: high intensity
 *  2: low intensity
 *  3: italic
 *  4: single line underscore
 *  5: slow blink
 *  6: fast blink
 *  7: reverse video
 *  8: hidden
 */

class AnsiConsole : Console
{
  private:
    FILE* _fp;

  public:
    @property FILE* fp() { return _fp; }

    static AnsiConsole create(FILE* fp, bool forceColors)
    {
        version (Posix)
        {
            import core.stdc.stdlib : getenv;
            import core.stdc.string : strcmp;

            const(char)* term = getenv("TERM");
            if (!forceColors && !(isatty(STDERR_FILENO) && term && term[0] && 0 != strcmp(term, "dumb")))
                return null;

            auto c = new AnsiConsole();
            c._fp = fp;
            return c;
        }
        else version (Windows)
        {
            import core.sys.windows.windows;
            import core.sys.windows.wincon;

            /* Windows 10 now support ANSI control sequences, but not by default.
             * we try enabling ANSI escape codes for the console if one is detected.
             */
            HANDLE con = getConsoleHandle(fp);
            if ((con && tryEnableConsoleAnsiCodes(con)) || forceColors)
            {
                auto c = new AnsiConsole();
                c._fp = fp;
                return c;
            }

            return null;
        }
        else
            return null;
    }

    void setColorBright(bool bright)
    {
        fprintf(_fp, "\033[%dm", bright);
    }

    void setColor(Color color)
    {
        fprintf(_fp, "\033[%d;%dm", color & Color.bright ? 1 : 0, 30 + (color & ~Color.bright));
    }

    void resetColor()
    {
        fputs("\033[m", _fp);
    }
}
