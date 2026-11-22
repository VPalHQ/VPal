// VPal Command Center look: custom-drawn controls for the control panel (PalworldSettingsEditor.ps1).
// The control panel compiles this file once with Add-Type and keeps the result in CommandCenter\data\ui.
// Written for C# 5 (the compiler that comes with Windows PowerShell 5.1). Unofficial fan tool. Not affiliated with Pocketpair.
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace VPalUi
{
    public static class Theme
    {
        public static Color Navy = Color.FromArgb(11, 18, 32);
        public static Color Card = Color.FromArgb(13, 23, 41);
        public static Color Card2 = Color.FromArgb(20, 33, 56);
        public static Color Card3 = Color.FromArgb(26, 41, 68);
        public static Color Line = Color.FromArgb(36, 54, 82);
        public static Color Border = Color.FromArgb(58, 86, 112);
        public static Color Teal = Color.FromArgb(46, 230, 214);
        public static Color TealSoft = Color.FromArgb(120, 222, 232);
        public static Color TealDeep = Color.FromArgb(18, 179, 179);
        public static Color Text = Color.FromArgb(238, 242, 248);
        public static Color Muted = Color.FromArgb(168, 181, 202);
        public static Color Faint = Color.FromArgb(118, 132, 156);
        public static Color Gold = Color.FromArgb(245, 192, 78);
        public static Color Orange = Color.FromArgb(255, 172, 66);
        public static Color Red = Color.FromArgb(255, 107, 107);
        public static Color Green = Color.FromArgb(61, 220, 132);

        public static Image Backdrop;
        public static Control Host;
        static Bitmap cache;
        static Size cacheSize;
        static readonly Dictionary<string, Image> icons = new Dictionary<string, Image>(StringComparer.OrdinalIgnoreCase);
        static readonly Dictionary<string, Font> fonts = new Dictionary<string, Font>();

        public static void LoadAssets(string folder)
        {
            string bd = Path.Combine(folder, "backdrop.jpg");
            if (File.Exists(bd)) Backdrop = LoadImage(bd);
            string dir = Path.Combine(folder, "icons");
            if (Directory.Exists(dir))
                foreach (string f in Directory.GetFiles(dir, "*.png"))
                {
                    try { icons[Path.GetFileNameWithoutExtension(f)] = LoadImage(f); } catch { }
                }
        }

        static Image LoadImage(string path)
        {
            // a copy in memory, so the file is never kept open (updates can replace it)
            byte[] data = File.ReadAllBytes(path);
            using (MemoryStream ms = new MemoryStream(data))
            using (Image img = Image.FromStream(ms))
                return new Bitmap(img);
        }

        public static Image Icon(string name)
        {
            Image img;
            if (name != null && icons.TryGetValue(name, out img)) return img;
            return null;
        }

        public static Font Font(float size, FontStyle style)
        {
            string key = size.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + (int)style;
            Font f;
            if (!fonts.TryGetValue(key, out f)) { f = new Font("Segoe UI", size, style); fonts[key] = f; }
            return f;
        }

        public static Color Alpha(Color c, int a) { return Color.FromArgb(Math.Max(0, Math.Min(255, a)), c.R, c.G, c.B); }

        public static Color Mix(Color a, Color b, float t)
        {
            return Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
        }

        public static GraphicsPath Round(RectangleF r, float radius)
        {
            GraphicsPath p = new GraphicsPath();
            float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
            if (d <= 0.5f) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        public static void FillRound(Graphics g, RectangleF r, float radius, Color fill, Color border, float borderWidth)
        {
            SmoothingMode old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath p = Round(r, radius))
            {
                if (fill.A > 0) using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);
                if (border.A > 0 && borderWidth > 0) using (Pen pen = new Pen(border, borderWidth)) g.DrawPath(pen, p);
            }
            g.SmoothingMode = old;
        }

        public static void DrawTinted(Graphics g, Image img, Rectangle dest, Color c)
        {
            if (img == null) return;
            ColorMatrix cm = new ColorMatrix(new float[][] {
                new float[] { 0, 0, 0, 0, 0 },
                new float[] { 0, 0, 0, 0, 0 },
                new float[] { 0, 0, 0, 0, 0 },
                new float[] { 0, 0, 0, c.A / 255f, 0 },
                new float[] { c.R / 255f, c.G / 255f, c.B / 255f, 0, 1 } });
            using (ImageAttributes ia = new ImageAttributes())
            {
                ia.SetColorMatrix(cm);
                InterpolationMode old = g.InterpolationMode;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.DrawImage(img, dest, 0, 0, img.Width, img.Height, GraphicsUnit.Pixel, ia);
                g.InterpolationMode = old;
            }
        }

        public static void DrawIcon(Graphics g, Image img, Rectangle dest)
        {
            if (img == null) return;
            InterpolationMode old = g.InterpolationMode;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(img, dest);
            g.InterpolationMode = old;
        }

        public static void DrawText(Graphics g, string text, Font font, Rectangle r, Color c, TextFormatFlags extra)
        {
            TextRenderer.DrawText(g, text ?? "", font, r, c, TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | extra);
        }

        public static Size Measure(string text, Font font)
        {
            return TextRenderer.MeasureText(text ?? "", font, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
        }

        // The night scene, laid out once over the whole window, so every panel that shows it lines up with the others.
        public static void PaintBackdrop(Control c, Graphics g, Color tint)
        {
            Rectangle r = new Rectangle(0, 0, c.Width, c.Height);
            bool drawn = false;
            if (Backdrop != null && Host != null && Host.IsHandleCreated && c.IsHandleCreated)
            {
                Size hs = Host.ClientSize;
                if (hs.Width > 0 && hs.Height > 0)
                {
                    if (cache == null || cacheSize != hs)
                    {
                        if (cache != null) cache.Dispose();
                        cache = new Bitmap(hs.Width, hs.Height, PixelFormat.Format32bppPArgb);
                        using (Graphics cg = Graphics.FromImage(cache))
                        {
                            cg.InterpolationMode = InterpolationMode.HighQualityBicubic;
                            float s = Math.Max(hs.Width / (float)Backdrop.Width, hs.Height / (float)Backdrop.Height);
                            float w = Backdrop.Width * s, h = Backdrop.Height * s;
                            cg.DrawImage(Backdrop, (hs.Width - w) / 2f, (hs.Height - h) / 2f, w, h);
                        }
                        cacheSize = hs;
                    }
                    Point p = Host.PointToClient(c.PointToScreen(Point.Empty));
                    g.DrawImage(cache, r, new Rectangle(p.X, p.Y, c.Width, c.Height), GraphicsUnit.Pixel);
                    drawn = true;
                }
            }
            if (!drawn) using (SolidBrush b = new SolidBrush(Navy)) g.FillRectangle(b, r);
            if (tint.A > 0) using (SolidBrush b = new SolidBrush(tint)) g.FillRectangle(b, r);
        }

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);

        public static void DarkScrollbars(Control c)
        {
            // dark scroll bars on Windows 10 (1809) and later; harmless elsewhere
            EventHandler apply = delegate(object s, EventArgs e)
            {
                try { SetWindowTheme(((Control)s).Handle, "DarkMode_Explorer", null); } catch { }
            };
            if (c.IsHandleCreated) apply(c, EventArgs.Empty);
            c.HandleCreated += apply;
        }

        public static ScrollableControl ScrollParent(Control c)
        {
            for (Control p = c.Parent; p != null; p = p.Parent)
            {
                ScrollableControl sc = p as ScrollableControl;
                if (sc != null && sc.AutoScroll) return sc;
            }
            return null;
        }

        // Draws what is behind a control (its parent's background) so rounded corners and glass blend in.
        // Only the background: the parent's own drawing never sits under its children, and repainting it made
        // every switch, stepper and badge repaint the whole settings list.
        internal static void PaintParent(Control self, PaintEventArgs e, Action<Control, PaintEventArgs> bg, Action<Control, PaintEventArgs> fg)
        {
            if (self.Parent == null) return;
            Graphics g = e.Graphics;
            GraphicsState st = g.Save();
            g.TranslateTransform(-self.Left, -self.Top);
            PaintEventArgs pe = new PaintEventArgs(g, new Rectangle(self.Left, self.Top, self.Width, self.Height));
            bg(self.Parent, pe);
            g.Restore(st);
        }

        public static void CreateHandles(Control c)
        {
            // builds the windows behind a control and everything in it now, so showing it later is quick
            if (c == null || c.IsDisposed) return;
            if (!c.IsHandleCreated) { IntPtr h = c.Handle; }
            foreach (Control k in c.Controls) CreateHandles(k);
        }
    }

    // A panel that shows the night scene (with an optional dark tint) behind its children.
    public class BackdropPanel : Panel
    {
        public Color Tint { get; set; }

        public BackdropPanel()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Navy;
            ForeColor = Theme.Text;
            Tint = Color.Empty;
        }

        protected override void OnPaintBackground(PaintEventArgs e) { Theme.PaintBackdrop(this, e.Graphics, Tint); }

        protected override void OnScroll(ScrollEventArgs se) { base.OnScroll(se); Invalidate(true); }

        protected override void OnMouseWheel(MouseEventArgs e) { base.OnMouseWheel(e); if (AutoScroll) Invalidate(true); }
    }

    // A rounded card. Glass cards let the night scene show through; solid cards are faster for long lists.
    public class Card : Panel
    {
        public int Radius { get; set; }
        public bool Glass { get; set; }
        public Color Fill { get; set; }
        public Color BorderColor { get; set; }
        public Image TitleIcon { get; set; }
        public Color TitleIconColor { get; set; }
        public int TitleHeight { get; set; }
        public Font TitleFont { get; set; }

        public Card()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            Radius = 12;
            Fill = Theme.Card;
            BorderColor = Theme.Alpha(Theme.TealSoft, 70);
            BackColor = Theme.Card;
            ForeColor = Theme.Text;
            TitleIconColor = Color.Empty;
            TitleHeight = 30;
        }

        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            Theme.PaintParent(this, e, InvokePaintBackground, InvokePaint);
            Color fill = Glass ? Theme.Alpha(Fill, 205) : Fill;
            Theme.FillRound(e.Graphics, new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Radius, fill, BorderColor, 1.2f);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            if (string.IsNullOrEmpty(Text)) return;
            int x = 14;
            if (TitleIcon != null)
            {
                Rectangle ir = new Rectangle(14, 9, 20, 20);
                if (TitleIconColor.A > 0) Theme.DrawTinted(e.Graphics, TitleIcon, ir, TitleIconColor);
                else Theme.DrawIcon(e.Graphics, TitleIcon, ir);
                x = 42;
            }
            Theme.DrawText(e.Graphics, Text, TitleFont ?? Font, new Rectangle(x, 8, Width - x - 10, TitleHeight - 6), Theme.Text, TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter);
        }
    }

    // Stands in for a GroupBox on the tool pages: same Location, Size, Text and child coordinates.
    public class CardGroup : Card
    {
        public CardGroup()
        {
            TitleFont = Theme.Font(10.5f, FontStyle.Bold);
            TitleHeight = 32;
        }
    }

    // A page of the control panel. Tool pages get their header and a scrolling body when they're added.
    public class Page : BackdropPanel
    {
        public string Group { get; set; }
        public string NavText { get; set; }
        public string Subtitle { get; set; }
        public string IconKey { get; set; }
        public int Order { get; set; }
        public bool WrapContent { get; set; }
        public PageHeader Header { get; private set; }
        public BackdropPanel Body { get; private set; }
        internal bool Wrapped;

        public Page()
        {
            Group = "";
            Subtitle = "";
            IconKey = "";
            Tint = Theme.Alpha(Theme.Navy, 70);
            Padding = new Padding(24, 0, 24, 0);
        }

        public PageHeader MakeHeader(string crumb)
        {
            if (Header == null)
            {
                Header = new PageHeader();
                Header.Dock = DockStyle.Top;
                Controls.Add(Header);
            }
            Header.Crumb = crumb;
            Header.Title = Text;
            Header.Subtitle = Subtitle;
            Header.Icon = Theme.Icon("ui_" + IconKey);
            return Header;
        }

        // moves everything already on the page into a scrolling body under the header
        internal void Wrap()
        {
            if (Wrapped) return;
            Wrapped = true;
            if (!WrapContent) return;
            List<Control> kids = new List<Control>();
            foreach (Control c in Controls) kids.Add(c);
            SuspendLayout();
            Body = new BackdropPanel();
            Body.Tint = Tint;
            Body.AutoScroll = true;
            Body.Dock = DockStyle.Fill;
            Body.Padding = new Padding(0, 0, 0, 16);
            Theme.DarkScrollbars(Body);
            // the card titles are taller than the old group box titles: move each card's contents down a little,
            // and everything under a card down by the same amount
            kids.Sort(delegate(Control a, Control b) { return a.Top.CompareTo(b.Top); });
            int offset = 0;
            foreach (Control c in kids)
            {
                Controls.Remove(c);
                c.Top += offset;
                CardGroup cg = c as CardGroup;
                if (cg != null)
                {
                    foreach (Control k in cg.Controls) k.Top += TitlePad;
                    cg.Height += TitlePad;
                    offset += TitlePad;
                    widths[cg] = cg.Width;
                    foreach (Control k in cg.Controls) if (k is ListView && k.Right > cg.Width - 40) widths[k] = k.Width;
                }
                Body.Controls.Add(c);
            }
            AutoScroll = false;
            Controls.Add(Body);
            MakeHeader(Group);
            Body.BringToFront();
            Body.Resize += delegate { Stretch(); };
            ResumeLayout(true);
        }

        const int TitlePad = 10;
        readonly Dictionary<Control, int> widths = new Dictionary<Control, int>();

        // cards (and the lists along their right edge) grow with the window
        void Stretch()
        {
            if (Body == null) return;
            int avail = Body.ClientSize.Width - 14;
            foreach (Control c in Body.Controls)
            {
                CardGroup cg = c as CardGroup;
                int w0;
                if (cg == null || !widths.TryGetValue(cg, out w0)) continue;
                int w = Math.Max(w0, avail - cg.Left);
                if (w == cg.Width) continue;
                int grow = w - w0;
                cg.Width = w;
                foreach (Control k in cg.Controls)
                {
                    int lw;
                    if (widths.TryGetValue(k, out lw)) k.Width = lw + grow;
                }
            }
        }
    }

    public class PageCollection : IEnumerable
    {
        readonly List<Page> list = new List<Page>();
        readonly PageHost owner;
        internal PageCollection(PageHost o) { owner = o; }
        public int Count { get { return list.Count; } }
        public Page this[int i] { get { return list[i]; } }
        public int IndexOf(Page p) { return list.IndexOf(p); }
        public bool Contains(Page p) { return list.Contains(p); }
        public void Add(Page p) { if (p == null || list.Contains(p)) return; list.Add(p); owner.Added(p); }
        public void Remove(Page p) { int i = list.IndexOf(p); if (i < 0) return; list.RemoveAt(i); owner.Removed(p, i); }
        public IEnumerator GetEnumerator() { return list.ToArray().GetEnumerator(); }
        internal List<Page> Items { get { return list; } }
    }

    // Holds the pages and shows one at a time; works like the TabControl it replaces (TabPages, SelectedIndex, SelectedTab).
    public class PageHost : BackdropPanel
    {
        public PageCollection TabPages { get; private set; }
        int sel = -1;
        public event EventHandler SelectedIndexChanged;
        public event EventHandler PagesChanged;
        readonly Timer warm = new Timer();

        [DllImport("user32.dll")]
        static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        const int WM_SETREDRAW = 0x000B;

        public PageHost()
        {
            TabPages = new PageCollection(this);
            Tint = Theme.Alpha(Theme.Navy, 70);
            warm.Interval = 60;
            warm.Tick += delegate { WarmNext(); };
        }

        bool Redraw(bool on)
        {
            if (!IsHandleCreated) return false;
            try { SendMessage(Handle, WM_SETREDRAW, on ? (IntPtr)1 : IntPtr.Zero, IntPtr.Zero); return true; }
            catch { return false; }
        }

        // Prepares the hidden pages one at a time (their windows and layout), so switching to them is instant.
        public void WarmUp() { warm.Stop(); warm.Start(); }

        void WarmNext()
        {
            foreach (Page p in TabPages.Items)
            {
                if (p.IsDisposed || p == SelectedTab || warmed.ContainsKey(p)) continue;
                SuspendLayout();
                try
                {
                    if (p.Size != ClientSize) p.Bounds = DisplayRectangle;
                    Theme.CreateHandles(p);
                    p.PerformLayout();
                }
                finally { ResumeLayout(false); }
                warmed[p] = true;
                return;
            }
            warm.Stop();
        }
        readonly Dictionary<Page, bool> warmed = new Dictionary<Page, bool>();

        public int SelectedIndex
        {
            get { return sel; }
            set
            {
                int v = (value >= 0 && value < TabPages.Count) ? value : (TabPages.Count > 0 ? 0 : -1);
                if (v == sel) return;
                bool paused = Redraw(false);
                SuspendLayout();
                try
                {
                    Page old = (sel >= 0 && sel < TabPages.Count) ? TabPages[sel] : null;
                    sel = v;
                    Page now = SelectedTab;
                    if (now != null) { now.Visible = true; now.BringToFront(); }
                    if (old != null && old != now) old.Visible = false;
                }
                finally
                {
                    ResumeLayout(true);
                    if (paused) { Redraw(true); Invalidate(true); Update(); }
                }
                if (SelectedIndexChanged != null) SelectedIndexChanged(this, EventArgs.Empty);
            }
        }

        public Page SelectedTab
        {
            get { return (sel >= 0 && sel < TabPages.Count) ? TabPages[sel] : null; }
            set { int i = TabPages.IndexOf(value); if (i >= 0) SelectedIndex = i; }
        }

        internal void Added(Page p)
        {
            p.Wrap();
            p.Dock = DockStyle.Fill;
            p.Visible = false;
            Controls.Add(p);
            if (sel < 0) SelectedIndex = TabPages.Count - 1;
            if (PagesChanged != null) PagesChanged(this, EventArgs.Empty);
        }

        internal void Removed(Page p, int index)
        {
            warmed.Remove(p);
            Controls.Remove(p);
            if (index == sel) sel = -1;
            else if (index < sel) sel--;
            if (PagesChanged != null) PagesChanged(this, EventArgs.Empty);
        }
    }

    // The settings list: a line under each row and a short divider before the unit and default, drawn here
    // (drawing them from PowerShell made every repaint slow).
    public class RowTable : TableLayoutPanel
    {
        public Color LineColor { get; set; }
        public int DividerColumn { get; set; }

        public RowTable()
        {
            LineColor = Theme.Line;
            DividerColumn = 3;
            DoubleBuffered = true;
        }

        protected override void OnCellPaint(TableLayoutCellPaintEventArgs e)
        {
            base.OnCellPaint(e);
            Rectangle b = e.CellBounds;
            using (Pen p = new Pen(LineColor))
            {
                if (e.Row < RowCount - 1)
                {
                    int l = b.Left + (e.Column == 0 ? 12 : 0);
                    int r = b.Right - (e.Column == ColumnCount - 1 ? 12 : 0);
                    e.Graphics.DrawLine(p, l, b.Bottom - 1, r, b.Bottom - 1);
                }
                if (e.Column == DividerColumn && b.Height > 40) e.Graphics.DrawLine(p, b.Left + 2, b.Top + 16, b.Left + 2, b.Bottom - 16);
            }
        }
    }

    // The breadcrumb, icon, title, subtitle and "N settings" chip at the top of a page.
    public class PageHeader : Control
    {
        string crumb = "", title = "", subtitle = "", chip = "";
        public Image Icon { get; set; }
        public string Crumb { get { return crumb; } set { crumb = value ?? ""; Invalidate(); } }
        public string Title { get { return title; } set { title = value ?? ""; Invalidate(); } }
        public string Subtitle { get { return subtitle; } set { subtitle = value ?? ""; Invalidate(); } }
        public string Chip { get { return chip; } set { chip = value ?? ""; Invalidate(); } }

        public PageHeader()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Height = 112;
        }

        protected override void OnPaintBackground(PaintEventArgs e) { Theme.PaintParent(this, e, InvokePaintBackground, InvokePaint); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Font small = Theme.Font(10f, FontStyle.Regular), smallB = Theme.Font(10f, FontStyle.Bold);
            int x = 0;
            Theme.DrawTinted(g, Theme.Icon("ui_home"), new Rectangle(x, 14, 16, 16), Theme.Muted);
            x += 22;
            Theme.DrawTinted(g, Theme.Icon("ui_chevron"), new Rectangle(x, 16, 12, 12), Theme.Faint);
            x += 18;
            Size cs = Theme.Measure(crumb, small);
            Theme.DrawText(g, crumb, small, new Rectangle(x, 12, cs.Width + 4, 20), Theme.Muted, TextFormatFlags.VerticalCenter);
            x += cs.Width + 8;
            Theme.DrawText(g, "/", small, new Rectangle(x, 12, 12, 20), Theme.Faint, TextFormatFlags.VerticalCenter);
            x += 14;
            Theme.DrawText(g, title, smallB, new Rectangle(x, 12, Width - x, 20), Theme.TealSoft, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);

            int tx = 0;
            if (Icon != null) { Theme.DrawTinted(g, Icon, new Rectangle(0, 44, 40, 40), Theme.Teal); tx = 54; }
            Font tf = Theme.Font(22f, FontStyle.Bold);
            int chipW = 0;
            if (chip.Length > 0)
            {
                Size s = Theme.Measure(chip, Theme.Font(9.75f, FontStyle.Regular));
                chipW = s.Width + 44;
                Rectangle cr = new Rectangle(Width - chipW - 2, 50, chipW, 32);
                Theme.FillRound(g, cr, 8, Theme.Alpha(Theme.Card, 210), Theme.Alpha(Theme.TealSoft, 90), 1.2f);
                Theme.DrawTinted(g, Theme.Icon("ui_gearsmall"), new Rectangle(cr.X + 10, cr.Y + 7, 18, 18), Theme.Text);
                Theme.DrawText(g, chip, Theme.Font(9.75f, FontStyle.Regular), new Rectangle(cr.X + 32, cr.Y, s.Width + 8, cr.Height), Theme.Text, TextFormatFlags.VerticalCenter);
            }
            Theme.DrawText(g, title, tf, new Rectangle(tx, 38, Width - tx - chipW - 12, 44), Theme.Text, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
            Theme.DrawText(g, subtitle, Theme.Font(11f, FontStyle.Regular), new Rectangle(tx + 2, 80, Width - tx - chipW - 12, 24), Theme.Muted, TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
        }
    }

    // The sidebar: logo, then the pages grouped under "SERVER" and "WORLD SETTINGS".
    public class NavList : Control
    {
        class Item { public string Text; public Page Page; public bool Header; public Rectangle Bounds; }
        readonly List<Item> items = new List<Item>();
        PageHost host;
        int hover = -1;
        public Image Logo { get; set; }
        public string Title { get; set; }
        public string Subtitle { get; set; }
        public Color SubtitleColor { get; set; }
        public string[] Groups { get; set; }
        public int LogoHeight { get; set; }

        public NavList()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            TabStop = true;
            Title = "VPal";
            Subtitle = "Server Command Center";
            SubtitleColor = Theme.Gold;
            Groups = new string[] { "Server", "World settings" };
            LogoHeight = 100;
            Width = 240;
            AccessibleName = "Sections";
            AccessibleRole = AccessibleRole.List;
        }

        public void Bind(PageHost h)
        {
            host = h;
            h.PagesChanged += delegate { Rebuild(); };
            h.SelectedIndexChanged += delegate { Invalidate(); };
            Rebuild();
        }

        public void Rebuild()
        {
            items.Clear();
            if (host == null) return;
            List<string> order = new List<string>(Groups);
            List<Page> pages = new List<Page>(host.TabPages.Items);
            foreach (Page p in pages) if (!order.Contains(p.Group ?? "")) order.Add(p.Group ?? "");
            foreach (string grp in order)
            {
                List<Page> inGroup = pages.FindAll(delegate(Page p) { return (p.Group ?? "") == grp; });
                if (inGroup.Count == 0) continue;
                inGroup.Sort(delegate(Page a, Page b)
                {
                    int c = a.Order.CompareTo(b.Order);
                    return c != 0 ? c : pages.IndexOf(a).CompareTo(pages.IndexOf(b));
                });
                if (grp.Length > 0) items.Add(new Item { Text = grp.ToUpperInvariant(), Header = true });
                foreach (Page p in inGroup) items.Add(new Item { Text = string.IsNullOrEmpty(p.NavText) ? p.Text : p.NavText, Page = p });
            }
            LayoutItems();
            Invalidate();
        }

        void LayoutItems()
        {
            int headers = 0, rows = 0;
            foreach (Item it in items) { if (it.Header) headers++; else rows++; }
            int avail = Height - LogoHeight - headers * 34 - 16;
            int ih = rows > 0 ? Math.Max(24, Math.Min(38, avail / rows)) : 34;
            int y = LogoHeight;
            foreach (Item it in items)
            {
                if (it.Header) { y += (y > LogoHeight ? 8 : 0); it.Bounds = new Rectangle(0, y, Width, 30); y += 30; }
                else { it.Bounds = new Rectangle(12, y, Width - 26, ih - 2); y += ih; }
            }
        }

        protected override void OnResize(EventArgs e) { base.OnResize(e); LayoutItems(); Invalidate(); }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            Theme.PaintBackdrop(this, e.Graphics, Theme.Alpha(Theme.Navy, 150));
        }

        // Spaced capitals (like the logo's "SERVER COMMAND CENTER"), shrunk until they fit.
        static void DrawCaps(Graphics g, string text, int x, int y, int width, Color color)
        {
            if (string.IsNullOrEmpty(text) || width <= 0) return;
            TextFormatFlags f = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine;
            for (float size = 8.5f; size >= 6.5f; size -= 0.5f)
            {
                Font font = Theme.Font(size, FontStyle.Bold);
                float track = size >= 8f ? 1.6f : 1.0f;
                int[] w = new int[text.Length];
                float total = 0;
                for (int i = 0; i < text.Length; i++)
                {
                    w[i] = text[i] == ' ' ? (int)Math.Round(size * 0.55f) : TextRenderer.MeasureText(g, text[i].ToString(), font, new Size(200, 40), f).Width;
                    total += w[i] + (i < text.Length - 1 ? track : 0);
                }
                if (total > width && size > 6.5f) continue;
                float cx = x;
                for (int i = 0; i < text.Length; i++)
                {
                    if (text[i] != ' ') TextRenderer.DrawText(g, text[i].ToString(), font, new Point((int)Math.Round(cx), y), color, f);
                    cx += w[i] + track;
                }
                return;
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            using (Pen edge = new Pen(Theme.Alpha(Theme.TealSoft, 45))) g.DrawLine(edge, Width - 1, 0, Width - 1, Height);
            if (Logo != null) Theme.DrawIcon(g, Logo, new Rectangle(8, 14, 74, 74));
            Theme.DrawText(g, Title, Theme.Font(22f, FontStyle.Bold), new Rectangle(84, 14, Width - 90, 42), Theme.Text, TextFormatFlags.VerticalCenter);
            DrawCaps(g, (Subtitle ?? "").ToUpperInvariant(), 86, 58, Width - 86 - 10, SubtitleColor);
            Page selPage = host != null ? host.SelectedTab : null;
            for (int i = 0; i < items.Count; i++)
            {
                Item it = items[i];
                Rectangle b = it.Bounds;
                if (it.Header)
                {
                    Theme.DrawText(g, it.Text, Theme.Font(9.5f, FontStyle.Bold), new Rectangle(20, b.Y + 4, Width - 30, 20), Theme.TealSoft, TextFormatFlags.VerticalCenter);
                    using (Pen p = new Pen(Theme.Alpha(Theme.TealSoft, 50))) g.DrawLine(p, 20, b.Bottom - 2, Width - 26, b.Bottom - 2);
                    continue;
                }
                bool selected = it.Page == selPage;
                if (selected) Theme.FillRound(g, b, 9, Theme.Alpha(Theme.Teal, 38), Theme.Teal, 1.6f);
                else if (i == hover && Enabled) Theme.FillRound(g, b, 9, Color.FromArgb(22, 255, 255, 255), Color.Empty, 0);
                int isz = Math.Min(22, b.Height - 6);
                Rectangle ir = new Rectangle(b.X + 12, b.Y + (b.Height - isz) / 2, isz, isz);
                Theme.DrawTinted(g, Theme.Icon("ui_" + it.Page.IconKey), ir, selected ? Theme.Text : Theme.TealSoft);
                Font f = Theme.Font(10.5f, selected ? FontStyle.Bold : FontStyle.Regular);
                Theme.DrawText(g, it.Text, f, new Rectangle(b.X + 44, b.Y, b.Width - 48, b.Height), Enabled ? Theme.Text : Theme.Faint, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
                if (selected && Focused && ShowFocusCues)
                    using (Pen p = new Pen(Theme.Text) { DashStyle = DashStyle.Dot }) g.DrawRectangle(p, b.X + 3, b.Y + 3, b.Width - 7, b.Height - 7);
            }
        }

        int HitTest(Point pt)
        {
            for (int i = 0; i < items.Count; i++) if (!items[i].Header && items[i].Bounds.Contains(pt)) return i;
            return -1;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            int h = HitTest(e.Location);
            Cursor = h >= 0 ? Cursors.Hand : Cursors.Default;
            if (h != hover) { hover = h; Invalidate(); }
        }

        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); if (hover != -1) { hover = -1; Invalidate(); } }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            Focus();
            int h = HitTest(e.Location);
            if (h >= 0 && e.Button == MouseButtons.Left && host != null) host.SelectedTab = items[h].Page;
        }

        protected override bool IsInputKey(Keys keyData)
        {
            Keys k = keyData & Keys.KeyCode;
            return k == Keys.Up || k == Keys.Down || k == Keys.Home || k == Keys.End || base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (host == null) return;
            List<Page> order = new List<Page>();
            foreach (Item it in items) if (!it.Header) order.Add(it.Page);
            if (order.Count == 0) return;
            int i = order.IndexOf(host.SelectedTab);
            if (e.KeyCode == Keys.Down) i = Math.Min(order.Count - 1, i + 1);
            else if (e.KeyCode == Keys.Up) i = Math.Max(0, i - 1);
            else if (e.KeyCode == Keys.Home) i = 0;
            else if (e.KeyCode == Keys.End) i = order.Count - 1;
            else return;
            host.SelectedTab = order[Math.Max(0, i)];
            e.Handled = true;
        }

        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
    }

    public enum ButtonKind { Outline, Accent, Primary, Danger, Gold }

    // Rounded buttons with an optional icon, drawn over whatever is behind them.
    public class RoundButton : Button
    {
        bool hover, down;
        public ButtonKind Kind { get; set; }
        public Image IconImage { get; set; }
        public int Radius { get; set; }

        public RoundButton()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            BackColor = Color.Transparent;
            ForeColor = Theme.Text;
            Cursor = Cursors.Hand;
            Radius = 8;
            Height = 36;
            Padding = new Padding(14, 0, 14, 0);
            Font = Theme.Font(10f, FontStyle.Regular);
        }

        public override Size GetPreferredSize(Size proposed)
        {
            Size t = Theme.Measure(Text, Font);
            int w = t.Width + Padding.Horizontal + (IconImage != null ? 26 : 0) + 4;
            return new Size(w, Math.Max(Height, t.Height + 14));
        }

        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hover = true; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hover = false; down = false; Invalidate(); }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button == MouseButtons.Left) { down = true; Invalidate(); } }
        protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); down = false; Invalidate(); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }
        protected override void OnPaintBackground(PaintEventArgs e) { }

        protected override void OnPaint(PaintEventArgs e)
        {
            Theme.PaintParent(this, e, InvokePaintBackground, InvokePaint);
            Graphics g = e.Graphics;
            Color fill, border, text;
            ButtonKind kind = Kind;
            if (kind == ButtonKind.Outline && Font.Bold) kind = ButtonKind.Accent;   // the main button of a card
            switch (kind)
            {
                case ButtonKind.Primary: fill = Theme.Teal; border = Theme.Teal; text = Color.FromArgb(6, 32, 31); break;
                case ButtonKind.Gold: fill = Theme.Gold; border = Theme.Gold; text = Color.FromArgb(40, 28, 0); break;
                case ButtonKind.Accent: fill = Theme.Alpha(Theme.Card, 200); border = Theme.Teal; text = Theme.Text; break;
                case ButtonKind.Danger: fill = Color.FromArgb(200, 52, 20, 30); border = Theme.Red; text = Theme.Text; break;
                default: fill = Theme.Alpha(Theme.Card, 200); border = Theme.Border; text = Theme.Text; break;
            }
            if (Enabled && hover)
            {
                if (kind == ButtonKind.Primary || kind == ButtonKind.Gold) fill = Theme.Mix(fill, Color.White, down ? 0.05f : 0.18f);
                else { fill = Theme.Alpha(Theme.Mix(fill, kind == ButtonKind.Danger ? Theme.Red : Theme.Teal, down ? 0.35f : 0.22f), 230); border = Theme.Mix(border, Color.White, 0.25f); }
            }
            if (!Enabled) { fill = Theme.Alpha(fill, fill.A / 2); border = Theme.Alpha(border, 90); text = Theme.Faint; }
            Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
            Theme.FillRound(g, new RectangleF(0.75f, 0.75f, Width - 2.5f, Height - 2.5f), Radius, fill, border, 1.5f);
            Size ts = Theme.Measure(Text, Font);
            int iw = IconImage != null ? 26 : 0;
            int x = (Width - ts.Width - iw) / 2;
            if (IconImage != null)
            {
                Color ic = (kind == ButtonKind.Danger) ? Theme.Red : (kind == ButtonKind.Primary || kind == ButtonKind.Gold) ? text : Theme.TealSoft;
                if (!Enabled) ic = Theme.Faint;
                Theme.DrawTinted(g, IconImage, new Rectangle(x, (Height - 18) / 2, 18, 18), ic);
            }
            Theme.DrawText(g, Text, Font, new Rectangle(x + iw, 0, Width - x - iw, Height), text, TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
            if (Focused && ShowFocusCues)
                using (Pen p = new Pen(Theme.Alpha(Theme.Text, 170)) { DashStyle = DashStyle.Dot }) g.DrawRectangle(p, 4, 4, Width - 9, Height - 9);
        }
    }

    // An on/off switch for the settings (it is still a CheckBox underneath).
    public class Toggle : CheckBox
    {
        public Toggle()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            AutoSize = false;
            Size = new Size(96, 30);
            Cursor = Cursors.Hand;
            BackColor = Color.Transparent;
            Font = Theme.Font(10f, FontStyle.Bold);
        }

        protected override void OnCheckedChanged(EventArgs e) { base.OnCheckedChanged(e); Invalidate(); }
        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }
        protected override void OnPaintBackground(PaintEventArgs e) { }

        protected override void OnPaint(PaintEventArgs e)
        {
            Theme.PaintParent(this, e, InvokePaintBackground, InvokePaint);
            Graphics g = e.Graphics;
            RectangleF track = new RectangleF(1, (Height - 24) / 2f, 46, 24);
            Color tf = Checked ? Theme.Teal : Color.FromArgb(52, 66, 92);
            if (!Enabled) tf = Theme.Alpha(tf, 110);
            Theme.FillRound(g, track, 12, tf, Checked ? Color.Empty : Theme.Border, 1f);
            float kx = Checked ? track.Right - 21 : track.X + 3;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush b = new SolidBrush(Enabled ? Color.White : Color.FromArgb(190, 200, 210))) g.FillEllipse(b, kx, track.Y + 3, 18, 18);
            g.SmoothingMode = SmoothingMode.Default;
            string t = string.IsNullOrEmpty(Text) ? (Checked ? "ON" : "OFF") : Text.ToUpperInvariant();
            Theme.DrawText(g, t, Font, new Rectangle(56, 0, Width - 56, Height), Enabled ? (Checked ? Theme.Text : Theme.Muted) : Theme.Faint, TextFormatFlags.VerticalCenter);
            if (Focused && ShowFocusCues)
                using (Pen p = new Pen(Theme.Alpha(Theme.Text, 170)) { DashStyle = DashStyle.Dot }) g.DrawRectangle(p, 0, 0, 48, Height - 1);
        }
    }

    // A check box for the tool pages: teal box, light text.
    public class Check : CheckBox
    {
        public Check()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            Cursor = Cursors.Hand;
        }

        public override Size GetPreferredSize(Size proposed)
        {
            Size t = Theme.Measure(Text, Font);
            return new Size(t.Width + 28, Math.Max(22, t.Height + 6));
        }

        protected override void OnCheckedChanged(EventArgs e) { base.OnCheckedChanged(e); Invalidate(); }
        protected override void OnPaintBackground(PaintEventArgs e) { }

        protected override void OnPaint(PaintEventArgs e)
        {
            Theme.PaintParent(this, e, InvokePaintBackground, InvokePaint);
            Graphics g = e.Graphics;
            Size t = Theme.Measure("Ag", Font);
            int by = Math.Max(0, (Math.Min(Height, t.Height + 6) - 18) / 2);
            RectangleF box = new RectangleF(1, by, 17, 17);
            Color border = Enabled ? (Checked ? Theme.Teal : Theme.Muted) : Theme.Faint;
            Theme.FillRound(g, box, 4, Checked ? (Enabled ? Theme.Teal : Theme.Alpha(Theme.Teal, 100)) : Theme.Card2, border, 1.4f);
            if (Checked)
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using (Pen p = new Pen(Color.FromArgb(6, 32, 31), 2.2f)) g.DrawLines(p, new PointF[] { new PointF(box.X + 4, box.Y + 9), new PointF(box.X + 7.5f, box.Y + 12.5f), new PointF(box.X + 13, box.Y + 5) });
                g.SmoothingMode = SmoothingMode.Default;
            }
            Color tc = Enabled ? (ForeColor.ToArgb() == SystemColors.ControlText.ToArgb() ? Theme.Text : ForeColor) : Theme.Faint;
            Theme.DrawText(g, Text, Font, new Rectangle(26, 0, Width - 26, Math.Max(Height, 20)), tc, TextFormatFlags.WordBreak | (Height <= t.Height + 8 ? TextFormatFlags.VerticalCenter : TextFormatFlags.Default));
            if (Focused && ShowFocusCues)
                using (Pen p = new Pen(Theme.Alpha(Theme.Text, 170)) { DashStyle = DashStyle.Dot }) g.DrawRectangle(p, 24, 0, Width - 25, Height - 1);
        }
    }

    // − value + around a NumericUpDown (which stays the real control, so the panel's code keeps working).
    public class Stepper : Panel
    {
        public NumericUpDown Num { get; private set; }
        readonly Panel clip;
        readonly Timer repeat = new Timer();
        int pressed;    // -1 minus, 1 plus
        int hoverZone;
        bool changed;
        public bool Changed { get { return changed; } set { changed = value; Invalidate(); } }
        const int Btn = 34;

        public Stepper(NumericUpDown num) : this(num, 150) { }

        public Stepper(NumericUpDown num, int width)
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Num = num;
            Size = new Size(width, 36);
            Margin = num.Margin;
            num.BorderStyle = BorderStyle.None;
            num.BackColor = Theme.Card2;
            num.ForeColor = Theme.Text;
            num.TextAlign = HorizontalAlignment.Center;
            num.Font = Theme.Font(11f, FontStyle.Bold);
            clip = new Panel();
            clip.BackColor = Theme.Card2;
            Controls.Add(clip);
            clip.Controls.Add(num);
            num.Margin = new Padding(0);
            num.Anchor = AnchorStyles.None;
            num.GotFocus += delegate { Invalidate(); };
            num.LostFocus += delegate { Invalidate(); };
            num.EnabledChanged += delegate { Invalidate(); };
            num.MouseWheel += delegate(object s, MouseEventArgs e)
            {
                // the mouse wheel scrolls the page instead of changing the value by accident
                HandledMouseEventArgs he = e as HandledMouseEventArgs;
                if (he != null) he.Handled = true;
                ScrollableControl sc = Theme.ScrollParent(this);
                if (sc != null)
                {
                    int y = -sc.AutoScrollPosition.Y - e.Delta;
                    sc.AutoScrollPosition = new Point(-sc.AutoScrollPosition.X, Math.Max(0, y));
                    sc.Invalidate(true);
                }
            };
            repeat.Tick += delegate { repeat.Interval = 60; Step(); };
            LayoutParts();
        }

        void LayoutParts()
        {
            int h = Num.PreferredHeight;
            clip.Bounds = new Rectangle(Btn + 1, Math.Max(2, (Height - h) / 2), Math.Max(10, Width - 2 * Btn - 2), h);
            Num.Bounds = new Rectangle(0, 0, clip.Width + 20, h);
        }

        protected override void OnResize(EventArgs e) { base.OnResize(e); if (clip != null) LayoutParts(); }

        void Step()
        {
            if (!Num.Enabled || Num.ReadOnly) return;
            if (pressed < 0) Num.DownButton();
            else if (pressed > 0) Num.UpButton();
        }

        int Zone(Point p) { return p.X < Btn ? -1 : (p.X >= Width - Btn ? 1 : 0); }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;
            pressed = Zone(e.Location);
            if (pressed == 0) { Num.Focus(); return; }
            Num.Focus();
            Step();
            repeat.Interval = 420;
            repeat.Start();
            Invalidate();
        }

        protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); repeat.Stop(); pressed = 0; Invalidate(); }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            int z = Zone(e.Location);
            Cursor = z != 0 ? Cursors.Hand : Cursors.Default;
            if (z != hoverZone) { hoverZone = z; Invalidate(); }
        }

        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); repeat.Stop(); pressed = 0; hoverZone = 0; Invalidate(); }

        protected override void OnPaintBackground(PaintEventArgs e) { Theme.PaintParent(this, e, InvokePaintBackground, InvokePaint); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            bool on = Num.Enabled && !Num.ReadOnly;
            Color border = changed ? Theme.Orange : (Num.Focused ? Theme.Teal : Theme.Border);
            RectangleF r = new RectangleF(0.75f, 0.75f, Width - 2.5f, Height - 2.5f);
            Theme.FillRound(g, r, 8, Theme.Card2, border, changed || Num.Focused ? 1.8f : 1.3f);
            using (Pen p = new Pen(Theme.Line)) { g.DrawLine(p, Btn, 6, Btn, Height - 7); g.DrawLine(p, Width - Btn - 1, 6, Width - Btn - 1, Height - 7); }
            if (hoverZone != 0 && on)
            {
                Rectangle hz = hoverZone < 0 ? new Rectangle(3, 3, Btn - 5, Height - 7) : new Rectangle(Width - Btn + 1, 3, Btn - 5, Height - 7);
                Theme.FillRound(g, hz, 6, Theme.Alpha(Theme.Teal, pressed == hoverZone ? 70 : 34), Color.Empty, 0);
            }
            Color gc = on ? Theme.Text : Theme.Faint;
            Theme.DrawTinted(g, Theme.Icon("ui_minus"), new Rectangle((Btn - 16) / 2, (Height - 16) / 2, 16, 16), gc);
            Theme.DrawTinted(g, Theme.Icon("ui_plus"), new Rectangle(Width - Btn + (Btn - 16) / 2 - 1, (Height - 16) / 2, 16, 16), gc);
        }

        protected override void Dispose(bool disposing) { if (disposing) repeat.Dispose(); base.Dispose(disposing); }
    }

    // A small rounded label: "Changed", "Locked", "hours", a count.
    public class Badge : Control
    {
        public Color Fill { get; set; }
        public Color BorderColor { get; set; }
        public Color TextColor { get; set; }

        public Badge()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Font = Theme.Font(9f, FontStyle.Regular);
            Fill = Color.FromArgb(60, 255, 172, 66);
            BorderColor = Theme.Orange;
            TextColor = Theme.Orange;
            Margin = new Padding(8, 3, 0, 0);
        }

        public override Size GetPreferredSize(Size proposed)
        {
            Size t = Theme.Measure(Text, Font);
            return new Size(t.Width + 20, t.Height + 8);
        }

        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Size = GetPreferredSize(Size.Empty); Invalidate(); }
        protected override void OnPaintBackground(PaintEventArgs e) { Theme.PaintParent(this, e, InvokePaintBackground, InvokePaint); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Theme.FillRound(e.Graphics, new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), (Height - 1) / 2f, Fill, BorderColor, 1.1f);
            Theme.DrawText(e.Graphics, Text, Font, new Rectangle(0, 0, Width, Height), TextColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
    }

    // A colored dot (unsaved changes, server state).
    public class Dot : Control
    {
        Color color = Theme.Faint;
        public Color DotColor { get { return color; } set { if (value == color) return; color = value; Invalidate(); } }

        public Dot()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Size = new Size(14, 14);
        }

        protected override void OnPaintBackground(PaintEventArgs e) { Theme.PaintParent(this, e, InvokePaintBackground, InvokePaint); }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            float d = Math.Min(Width, Height) - 2;
            using (SolidBrush b = new SolidBrush(Theme.Alpha(color, 60))) e.Graphics.FillEllipse(b, 0, 0, d + 1, d + 1);
            using (SolidBrush b = new SolidBrush(color)) e.Graphics.FillEllipse(b, 2.5f, 2.5f, d - 4, d - 4);
        }
    }

    // The glass card at the top: server icon, server name, state and players online.
    public class StatusCard : Control
    {
        string server = "", state = "", players = "";
        Color stateColor = Theme.Faint;
        public string ServerName { get { return server; } set { if ((value ?? "") == server) return; server = value ?? ""; Relayout(); } }
        public string State { get { return state; } set { if ((value ?? "") == state) return; state = value ?? ""; Relayout(); } }
        public Color StateColor { get { return stateColor; } set { if (value == stateColor) return; stateColor = value; Invalidate(); } }
        public string Players { get { return players; } set { if ((value ?? "") == players) return; players = value ?? ""; Relayout(); } }

        public StatusCard()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Height = 58;
        }

        void Relayout() { Size s = GetPreferredSize(Size.Empty); if (s.Width != Width) Width = s.Width; Invalidate(); }

        public override Size GetPreferredSize(Size proposed)
        {
            int w = 18 + 30 + 12 + Theme.Measure(server, Theme.Font(17f, FontStyle.Bold)).Width + 26
                    + 18 + Theme.Measure(state, Theme.Font(11.5f, FontStyle.Bold)).Width + 26;
            if (players.Length > 0) w += 30 + Theme.Measure(players, Theme.Font(11.5f, FontStyle.Regular)).Width + 22;
            return new Size(w, Height);
        }

        protected override void OnPaintBackground(PaintEventArgs e) { Theme.PaintParent(this, e, InvokePaintBackground, InvokePaint); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Theme.FillRound(g, new RectangleF(0.75f, 0.75f, Width - 2.5f, Height - 2.5f), 12, Theme.Alpha(Theme.Card, 210), Theme.Alpha(Theme.TealSoft, 80), 1.2f);
            int x = 18;
            Theme.DrawTinted(g, Theme.Icon("ui_rack"), new Rectangle(x, (Height - 30) / 2, 30, 30), Theme.TealSoft);
            x += 42;
            Font nf = Theme.Font(17f, FontStyle.Bold);
            Size ns = Theme.Measure(server, nf);
            Theme.DrawText(g, server, nf, new Rectangle(x, 0, ns.Width + 4, Height), Theme.Text, TextFormatFlags.VerticalCenter);
            x += ns.Width + 14;
            using (Pen p = new Pen(Theme.Alpha(Theme.TealSoft, 60))) g.DrawLine(p, x, 16, x, Height - 17);
            x += 14;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush b = new SolidBrush(Theme.Alpha(stateColor, 70))) g.FillEllipse(b, x - 2, Height / 2 - 8, 16, 16);
            using (SolidBrush b = new SolidBrush(stateColor)) g.FillEllipse(b, x + 1, Height / 2 - 5, 10, 10);
            g.SmoothingMode = SmoothingMode.Default;
            x += 20;
            Font sf = Theme.Font(11.5f, FontStyle.Bold);
            Size ss = Theme.Measure(state, sf);
            Theme.DrawText(g, state, sf, new Rectangle(x, 0, ss.Width + 4, Height), stateColor, TextFormatFlags.VerticalCenter);
            x += ss.Width + 14;
            if (players.Length > 0)
            {
                using (Pen p = new Pen(Theme.Alpha(Theme.TealSoft, 60))) g.DrawLine(p, x, 16, x, Height - 17);
                x += 14;
                Theme.DrawTinted(g, Theme.Icon("ui_players"), new Rectangle(x, (Height - 22) / 2, 22, 22), Theme.TealSoft);
                x += 30;
                Theme.DrawText(g, players, Theme.Font(11.5f, FontStyle.Regular), new Rectangle(x, 0, Width - x, Height), Theme.Text, TextFormatFlags.VerticalCenter);
            }
        }
    }

    // A ListView with a dark header and rows.
    public class DarkList : ListView
    {
        bool fitting;

        public DarkList()
        {
            OwnerDraw = true;
            View = View.Details;
            FullRowSelect = true;
            BorderStyle = BorderStyle.None;
            BackColor = Theme.Card2;
            ForeColor = Theme.Text;
            DoubleBuffered = true;
            Theme.DarkScrollbars(this);
        }

        protected override void OnDrawColumnHeader(DrawListViewColumnHeaderEventArgs e)
        {
            using (SolidBrush b = new SolidBrush(Theme.Card3)) e.Graphics.FillRectangle(b, e.Bounds);
            using (Pen p = new Pen(Theme.Line)) { e.Graphics.DrawLine(p, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1); e.Graphics.DrawLine(p, e.Bounds.Right - 1, e.Bounds.Top + 4, e.Bounds.Right - 1, e.Bounds.Bottom - 5); }
            Rectangle r = new Rectangle(e.Bounds.X + 6, e.Bounds.Y, e.Bounds.Width - 10, e.Bounds.Height);
            Theme.DrawText(e.Graphics, e.Header.Text, Theme.Font(9f, FontStyle.Bold), r, Theme.TealSoft, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
        }

        protected override void OnDrawItem(DrawListViewItemEventArgs e)
        {
            if (View != View.Details) e.DrawDefault = true;
        }

        protected override void OnDrawSubItem(DrawListViewSubItemEventArgs e)
        {
            bool sel = e.Item.Selected;
            Color bg = sel ? Theme.Mix(Theme.Card2, Theme.Teal, 0.28f) : (e.ItemIndex % 2 == 0 ? Theme.Card2 : Theme.Mix(Theme.Card2, Theme.Card3, 0.5f));
            using (SolidBrush b = new SolidBrush(bg)) e.Graphics.FillRectangle(b, e.Bounds);
            Color fc = (e.Item.UseItemStyleForSubItems || e.ColumnIndex == 0) ? e.Item.ForeColor : e.SubItem.ForeColor;
            if (fc.ToArgb() == SystemColors.WindowText.ToArgb() || fc.ToArgb() == Color.Black.ToArgb()) fc = Theme.Text;
            Rectangle r = new Rectangle(e.Bounds.X + 6, e.Bounds.Y, e.Bounds.Width - 10, e.Bounds.Height);
            TextFormatFlags al = TextFormatFlags.Left;
            if (e.Header != null && e.Header.TextAlign == HorizontalAlignment.Right) al = TextFormatFlags.Right;
            else if (e.Header != null && e.Header.TextAlign == HorizontalAlignment.Center) al = TextFormatFlags.HorizontalCenter;
            Theme.DrawText(e.Graphics, e.SubItem.Text, Font, r, fc, al | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
        }

        protected override void OnResize(EventArgs e) { base.OnResize(e); FitLastColumn(); }
        protected override void OnColumnWidthChanged(ColumnWidthChangedEventArgs e) { base.OnColumnWidthChanged(e); FitLastColumn(); }

        public void FitLastColumn()
        {
            // the last column fills the rest, so no light gap shows at the right of the header
            if (fitting || Columns.Count == 0 || !IsHandleCreated) return;
            fitting = true;
            try
            {
                int used = 0;
                for (int i = 0; i < Columns.Count - 1; i++) used += Columns[i].Width;
                int w = ClientSize.Width - used;
                ColumnHeader last = Columns[Columns.Count - 1];
                if (w > 40 && last.Width != w) last.Width = w;
            }
            finally { fitting = false; }
        }

        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); FitLastColumn(); }
    }

    // Draws the dark look onto ordinary controls (dialogs, the setup window, anything not built from the controls above).
    public static class Dark
    {
        public static void Apply(Control root)
        {
            Style(root);
            foreach (Control c in root.Controls) Apply(c);
        }

        static bool Default(Color c, Color sys) { return c.ToArgb() == sys.ToArgb(); }

        static void Style(Control c)
        {
            if (c is BackdropPanel || c is Card || c is NavList || c is RoundButton || c is Toggle || c is Check
                || c is Stepper || c is Badge || c is Dot || c is StatusCard || c is DarkList || c is PageHeader) return;
            if (c is Form) { c.BackColor = Theme.Card; c.ForeColor = Theme.Text; return; }
            if (c is TextBoxBase)
            {
                TextBoxBase t = (TextBoxBase)c;
                t.BackColor = ((t is TextBox && ((TextBox)t).ReadOnly) || (t is RichTextBox && ((RichTextBox)t).ReadOnly)) ? Theme.Card3 : Theme.Card2;
                if (Default(t.ForeColor, SystemColors.WindowText) || Default(t.ForeColor, SystemColors.ControlText)) t.ForeColor = Theme.Text;
                if (t is TextBox && t.BorderStyle == BorderStyle.Fixed3D) t.BorderStyle = BorderStyle.FixedSingle;
                return;
            }
            if (c is ComboBox)
            {
                ComboBox cb = (ComboBox)c;
                cb.FlatStyle = FlatStyle.Flat;
                cb.BackColor = Theme.Card2;
                cb.ForeColor = Theme.Text;
                return;
            }
            if (c is NumericUpDown) { c.BackColor = Theme.Card2; c.ForeColor = Theme.Text; return; }
            if (c is ListView) { c.BackColor = Theme.Card2; c.ForeColor = Theme.Text; return; }
            if (c is Button)
            {
                Button b = (Button)c;
                b.FlatStyle = FlatStyle.Flat;
                b.BackColor = Theme.Card2;
                b.ForeColor = Theme.Text;
                b.FlatAppearance.BorderColor = Theme.Border;
                b.FlatAppearance.MouseOverBackColor = Theme.Mix(Theme.Card2, Theme.Teal, 0.25f);
                b.FlatAppearance.MouseDownBackColor = Theme.Mix(Theme.Card2, Theme.Teal, 0.4f);
                b.UseVisualStyleBackColor = false;
                return;
            }
            if (c is CheckBox || c is RadioButton)
            {
                ButtonBase b = (ButtonBase)c;
                b.FlatStyle = FlatStyle.Flat;
                if (Default(b.ForeColor, SystemColors.ControlText)) b.ForeColor = Theme.Text;
                return;
            }
            if (c is LinkLabel)
            {
                LinkLabel l = (LinkLabel)c;
                l.LinkColor = Theme.Teal; l.ActiveLinkColor = Theme.TealSoft; l.VisitedLinkColor = Theme.Teal;
                return;
            }
            if (c is GroupBox) { c.ForeColor = Theme.Text; return; }
            if (c is Label)
            {
                if (Default(c.ForeColor, SystemColors.ControlText)) c.ForeColor = Theme.Text;
                return;
            }
        }
    }
}
