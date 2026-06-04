#!/usr/bin/env python3
"""
Photo Eraser & Watermark Tool
Select rectangular regions to erase and apply watermark text to images.

Usage:
    python3 foto_editor.py

Controls:
    - Click & drag to draw selection rectangles (red dashed)
    - Select a rect in the list and click "Remove Selected" to delete it
    - Choose erase method: Fill (solid color) or Inpaint (smart fill)
    - Configure watermark text, size, opacity, position, color
    - Click "APPLY EFFECTS" to process
    - Save the result
"""

import tkinter as tk
from tkinter import filedialog, ttk, colorchooser, messagebox
from PIL import Image, ImageTk, ImageDraw, ImageFont
import numpy as np
import os
import sys

try:
    import cv2
    CV2_OK = True
except ImportError:
    CV2_OK = False


class EraseWatermarkApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Photo Eraser & Watermark")
        self.root.geometry("1200x800")
        self.root.minsize(900, 600)

        # Image state
        self.image_path = None
        self.original_image = None
        self.work_image = None
        self.display_image = None
        self.tk_image = None

        # Selection state (display coordinates relative to image top-left)
        self.rects = []
        self.rect_ids = []
        self.current_rect_id = None
        self.drag_start = None

        # Display geometry
        self.scale = 1.0
        self.offset_x = 0
        self.offset_y = 0

        # Watermark settings
        self.watermark_text = tk.StringVar(value="CONFIDENCIAL")
        self.font_size = tk.IntVar(value=48)
        self.watermark_color = "#ffffff"
        self.watermark_opacity = tk.DoubleVar(value=0.4)
        self.watermark_position = tk.StringVar(value="bottom-right")

        # Erase settings
        self.erase_method = tk.StringVar(
            value="inpaint" if CV2_OK else "fill"
        )
        self.fill_color = tk.StringVar(value="#ffffff")

        self._setup_ui()
        self._bind_shortcuts()

    # ------------------------------------------------------------------
    # UI
    # ------------------------------------------------------------------
    def _setup_ui(self):
        menubar = tk.Menu(self.root)
        self.root.config(menu=menubar)
        fm = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="File", menu=fm)
        fm.add_command(label="Open", command=self.open_image, accelerator="Ctrl+O")
        fm.add_command(label="Save As...", command=self.save_image, accelerator="Ctrl+S")
        fm.add_separator()
        fm.add_command(label="Exit", command=self.root.quit)

        main = ttk.Frame(self.root)
        main.pack(fill=tk.BOTH, expand=True, padx=6, pady=6)

        # -- Canvas --------------------------------------------------------
        canvas_frame = ttk.Frame(main)
        canvas_frame.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        self.canvas = tk.Canvas(canvas_frame, bg="#2d2d2d", cursor="cross")
        self.canvas.pack(fill=tk.BOTH, expand=True)

        self.canvas.bind("<ButtonPress-1>", self._on_drag_start)
        self.canvas.bind("<B1-Motion>", self._on_drag_move)
        self.canvas.bind("<ButtonRelease-1>", self._on_drag_end)

        # -- Controls ------------------------------------------------------
        ctrl = ttk.Frame(main, width=260)
        ctrl.pack(side=tk.RIGHT, fill=tk.Y, padx=(10, 0))
        ctrl.pack_propagate(False)

        row = 0

        # Image
        self._section_label(ctrl, "Image", row).grid(row=row, column=0, sticky=tk.W, pady=(0, 4))
        row += 1
        ttk.Button(ctrl, text="Open Image", command=self.open_image).grid(
            row=row, column=0, sticky=tk.EW, pady=1
        )
        row += 1
        ttk.Button(ctrl, text="Save Result", command=self.save_image).grid(
            row=row, column=0, sticky=tk.EW, pady=1
        )
        row += 1
        self._separator(ctrl, row).grid(row=row, column=0, sticky=tk.EW, pady=8)
        row += 1

        # Selections
        self._section_label(ctrl, "Selections", row).grid(
            row=row, column=0, sticky=tk.W, pady=(0, 4)
        )
        row += 1
        ttk.Button(ctrl, text="Clear All", command=self.clear_rects).grid(
            row=row, column=0, sticky=tk.EW, pady=1
        )
        row += 1
        self.rect_lb = tk.Listbox(ctrl, height=5)
        self.rect_lb.grid(row=row, column=0, sticky=tk.EW, pady=3)
        row += 1
        ttk.Button(ctrl, text="Remove Selected", command=self._remove_selected).grid(
            row=row, column=0, sticky=tk.EW, pady=1
        )
        row += 1
        self._separator(ctrl, row).grid(row=row, column=0, sticky=tk.EW, pady=8)
        row += 1

        # Erase method
        self._section_label(ctrl, "Erase Method", row).grid(
            row=row, column=0, sticky=tk.W, pady=(0, 4)
        )
        row += 1
        ef = ttk.Frame(ctrl)
        ef.grid(row=row, column=0, sticky=tk.W, pady=1)
        ttk.Radiobutton(ef, text="Fill Color", variable=self.erase_method, value="fill").pack(
            anchor=tk.W
        )
        if CV2_OK:
            ttk.Radiobutton(ef, text="Inpaint (smart)", variable=self.erase_method, value="inpaint").pack(
                anchor=tk.W
            )
        row += 1
        ttk.Button(ctrl, text="Fill Color...", command=self._pick_fill_color).grid(
            row=row, column=0, sticky=tk.W, pady=2
        )
        row += 1
        self._separator(ctrl, row).grid(row=row, column=0, sticky=tk.EW, pady=8)
        row += 1

        # Watermark
        self._section_label(ctrl, "Watermark", row).grid(
            row=row, column=0, sticky=tk.W, pady=(0, 4)
        )
        row += 1
        ttk.Label(ctrl, text="Text:").grid(row=row, column=0, sticky=tk.W)
        row += 1
        ttk.Entry(ctrl, textvariable=self.watermark_text).grid(
            row=row, column=0, sticky=tk.EW, pady=1
        )
        row += 1
        ttk.Label(ctrl, text=f"Font Size: 48").grid(row=row, column=0, sticky=tk.W)
        self._font_size_label = ctrl.winfo_children()[-1]
        fs = ttk.Scale(ctrl, from_=10, to_=200, variable=self.font_size, orient=tk.HORIZONTAL,
                        command=lambda v: self._font_size_label.config(text=f"Font Size: {int(float(v))}"))
        fs.grid(row=row + 1, column=0, sticky=tk.EW, pady=1)
        row += 2
        ttk.Label(ctrl, text=f"Opacity: 40%").grid(row=row, column=0, sticky=tk.W)
        self._opacity_label = ctrl.winfo_children()[-1]
        op = ttk.Scale(ctrl, from_=0.0, to_=1.0, variable=self.watermark_opacity,
                        orient=tk.HORIZONTAL,
                        command=lambda v: self._opacity_label.config(text=f"Opacity: {int(float(v)*100)}%"))
        op.grid(row=row + 1, column=0, sticky=tk.EW, pady=1)
        row += 2
        ttk.Label(ctrl, text="Position:").grid(row=row, column=0, sticky=tk.W)
        row += 1
        pos_cb = ttk.Combobox(
            ctrl,
            textvariable=self.watermark_position,
            values=["top-left", "top-right", "bottom-left", "bottom-right", "center", "tiled", "diagonal-tiled"],
            state="readonly",
        )
        pos_cb.grid(row=row, column=0, sticky=tk.EW, pady=1)
        row += 1
        ttk.Label(ctrl, text="Color:").grid(row=row, column=0, sticky=tk.W)
        row += 1
        cf = ttk.Frame(ctrl)
        cf.grid(row=row, column=0, sticky=tk.W, pady=2)
        self.color_btn = tk.Button(cf, bg=self.watermark_color, width=3,
                                    command=self._pick_watermark_color)
        self.color_btn.pack(side=tk.LEFT)
        ttk.Button(cf, text="Choose", command=self._pick_watermark_color).pack(
            side=tk.LEFT, padx=5
        )
        row += 1
        self._separator(ctrl, row).grid(row=row, column=0, sticky=tk.EW, pady=8)
        row += 1

        # Apply
        self._apply_btn = ttk.Button(
            ctrl, text="APPLY EFFECTS", command=self.apply,
        )
        self._apply_btn.grid(row=row, column=0, sticky=tk.EW, pady=6)
        row += 1

        # Make control columns expand
        ctrl.columnconfigure(0, weight=1)

    @staticmethod
    def _section_label(parent, text, row):
        return ttk.Label(parent, text=text, font=("", 11, "bold"))

    @staticmethod
    def _separator(parent, row):
        return ttk.Separator(parent, orient=tk.HORIZONTAL)

    def _bind_shortcuts(self):
        self.root.bind("<Control-o>", lambda e: self.open_image())
        self.root.bind("<Control-s>", lambda e: self.save_image())

    # ------------------------------------------------------------------
    # Image I/O
    # ------------------------------------------------------------------
    def open_image(self, event=None):
        path = filedialog.askopenfilename(
            title="Select an image",
            filetypes=[
                ("Image files", "*.png *.jpg *.jpeg *.bmp *.tiff *.webp"),
                ("All files", "*.*"),
            ],
        )
        if not path:
            return
        self.image_path = path
        self.original_image = Image.open(path).convert("RGBA")
        self.work_image = self.original_image.copy()
        self._reset_selections()
        self._render()

    def save_image(self, event=None):
        if self.work_image is None:
            messagebox.showwarning("No Image", "No image to save.")
            return
        path = filedialog.asksaveasfilename(
            title="Save image as",
            defaultextension=".png",
            filetypes=[
                ("PNG", "*.png"),
                ("JPEG", "*.jpg"),
                ("All files", "*.*"),
            ],
        )
        if not path:
            return
        ext = os.path.splitext(path)[1].lower()
        img = self.work_image
        if ext in (".jpg", ".jpeg"):
            img = img.convert("RGB")
        img.save(path)
        messagebox.showinfo("Saved", f"Image saved to:\n{path}")

    # ------------------------------------------------------------------
    # Display
    # ------------------------------------------------------------------
    def _render(self):
        """Draw the current work_image onto the canvas."""
        if self.original_image is None:
            return
        self.canvas.delete("all")
        cw = max(self.canvas.winfo_width(), 100)
        ch = max(self.canvas.winfo_height(), 100)

        img = self.work_image
        iw, ih = img.size
        scale = min(cw / iw, ch / ih)
        nw = max(int(iw * scale), 1)
        nh = max(int(ih * scale), 1)

        self.scale = scale
        self.display_image = img.resize((nw, nh), Image.LANCZOS)
        self.tk_image = ImageTk.PhotoImage(self.display_image)

        self.offset_x = (cw - nw) // 2
        self.offset_y = (ch - nh) // 2

        self.canvas.create_image(
            self.offset_x, self.offset_y, anchor=tk.NW, image=self.tk_image
        )
        # Redraw stored rects
        self.rect_ids = []
        for r in self.rects:
            self.rect_ids.append(self._canvas_rect(r))

    def _canvas_rect(self, rect):
        """Draw a single rectangle on the canvas (display coords)."""
        x1, y1, x2, y2 = rect
        return self.canvas.create_rectangle(
            x1 + self.offset_x,
            y1 + self.offset_y,
            x2 + self.offset_x,
            y2 + self.offset_y,
            outline="#ff4444",
            width=2,
            dash=(5, 4),
        )

    # ------------------------------------------------------------------
    # Mouse drag – draw selection rectangles
    # ------------------------------------------------------------------
    def _on_drag_start(self, event):
        self.drag_start = (event.x, event.y)
        self.current_rect_id = self.canvas.create_rectangle(
            event.x, event.y, event.x, event.y,
            outline="#ff4444", width=2, dash=(5, 4),
        )

    def _on_drag_move(self, event):
        if self.current_rect_id is None:
            return
        sx, sy = self.drag_start
        self.canvas.coords(self.current_rect_id, sx, sy, event.x, event.y)

    def _on_drag_end(self, event):
        if self.current_rect_id is None:
            return
        sx, sy = self.drag_start
        x1 = min(sx, event.x) - self.offset_x
        y1 = min(sy, event.y) - self.offset_y
        x2 = max(sx, event.x) - self.offset_x
        y2 = max(sy, event.y) - self.offset_y

        # Clamp to image bounds
        if self.display_image:
            dw, dh = self.display_image.size
            x1 = max(0, min(x1, dw))
            y1 = max(0, min(y1, dh))
            x2 = max(0, min(x2, dw))
            y2 = max(0, min(y2, dh))

        if (x2 - x1) > 8 and (y2 - y1) > 8:
            rect = (x1, y1, x2, y2)
            self.rects.append(rect)
            self.rect_ids.append(self.current_rect_id)
            self.rect_lb.insert(tk.END, f"Rect {len(self.rects)}  {int(x1)},{int(y1)} → {int(x2)},{int(y2)}")
            self.rect_lb.see(tk.END)
        else:
            self.canvas.delete(self.current_rect_id)
        self.current_rect_id = None
        self.drag_start = None

    # ------------------------------------------------------------------
    # Selection management
    # ------------------------------------------------------------------
    def _reset_selections(self):
        self.rects.clear()
        self.rect_ids.clear()
        self.rect_lb.delete(0, tk.END)

    def clear_rects(self):
        for rid in self.rect_ids:
            self.canvas.delete(rid)
        self._reset_selections()

    def _remove_selected(self):
        sel = self.rect_lb.curselection()
        if not sel:
            return
        idx = sel[0]
        self.canvas.delete(self.rect_ids.pop(idx))
        self.rects.pop(idx)
        self.rect_lb.delete(idx)

    # ------------------------------------------------------------------
    # Color pickers
    # ------------------------------------------------------------------
    def _pick_fill_color(self):
        c = colorchooser.askcolor(title="Fill Color", initialcolor=self.fill_color.get())
        if c[1]:
            self.fill_color.set(c[1])

    def _pick_watermark_color(self):
        c = colorchooser.askcolor(title="Watermark Color", initialcolor=self.watermark_color)
        if c[1]:
            self.watermark_color = c[1]
            self.color_btn.config(bg=self.watermark_color)

    # ------------------------------------------------------------------
    # Apply effects
    # ------------------------------------------------------------------
    def apply(self):
        if self.original_image is None:
            messagebox.showwarning("No Image", "Open an image first.")
            return
        if not self.watermark_text.get().strip():
            messagebox.showwarning("No Text", "Enter watermark text.")
            return

        img = self.original_image.copy()
        img_np = np.array(img)

        # Convert rects from display → original coordinates
        orig_rects = []
        for x1, y1, x2, y2 in self.rects:
            ox1 = int(x1 / self.scale)
            oy1 = int(y1 / self.scale)
            ox2 = int(x2 / self.scale)
            oy2 = int(y2 / self.scale)
            # clamp
            h, w = img_np.shape[:2]
            ox1, ox2 = max(0, ox1), min(w, ox2)
            oy1, oy2 = max(0, oy1), min(h, oy2)
            if ox2 > ox1 and oy2 > oy1:
                orig_rects.append((ox1, oy1, ox2, oy2))

        if not orig_rects and self.rects:
            messagebox.showwarning("Tiny selection", "Selections are too small.")
            return

        # --- Erase --------------------------------------------------------
        method = self.erase_method.get()
        if method == "fill":
            fill = self._hex_to_rgba(self.fill_color.get())
            for x1, y1, x2, y2 in orig_rects:
                img_np[y1:y2, x1:x2] = fill
        elif method == "inpaint" and CV2_OK:
            # Build a single mask for all rects
            mask = np.zeros(img_np.shape[:2], dtype=np.uint8)
            for x1, y1, x2, y2 in orig_rects:
                mask[y1:y2, x1:x2] = 255
            # Inpaint on RGB channels, preserve alpha
            rgb = cv2.cvtColor(img_np[:, :, :3], cv2.COLOR_RGBA2RGB)
            inp = cv2.inpaint(rgb, mask, 5, cv2.INPAINT_TELEA)
            img_np[:, :, :3] = inp
            # If the image has alpha, blend the inpainted region with original
            # so that transparent areas stay transparent.
            if img_np.shape[2] == 4:
                alpha = img_np[:, :, 3]
                # Restore original alpha in the mask area
                orig = np.array(self.original_image)
                alpha_mask = mask > 0
                # Keep original alpha where we inpainted
                img_np[:, :, 3] = np.where(alpha_mask, orig[:, :, 3], alpha)

        img = Image.fromarray(img_np)

        # --- Watermark ----------------------------------------------------
        img = self._add_watermark(img)

        self.work_image = img
        self._reset_selections()
        self._render()

        messagebox.showinfo(
            "Done",
            f"Effects applied.\n"
            f"  • {len(orig_rects)} region(s) erased ({method})\n"
            f"  • Watermark: \"{self.watermark_text.get()}\"",
        )

    @staticmethod
    def _hex_to_rgba(hex_str):
        h = hex_str.lstrip("#")
        return (*tuple(int(h[i:i+2], 16) for i in (0, 2, 4)), 255)

    def _add_watermark(self, img):
        text = self.watermark_text.get().strip()
        if not text:
            return img

        img = img.convert("RGBA")
        overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
        draw = ImageDraw.Draw(overlay)

        font = self._get_font()
        r, g, b = self._hex_to_rgb(self.watermark_color)
        a = int(255 * self.watermark_opacity.get())
        fill = (r, g, b, a)

        bbox = draw.textbbox((0, 0), text, font=font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        margin = int(self.font_size.get() * 0.5)

        pos = self.watermark_position.get()
        iw, ih = img.size

        if pos == "tiled":
            step_y = th + int(self.font_size.get() * 2)
            step_x = tw + int(self.font_size.get() * 2.5)
            for y in range(margin, ih, step_y):
                for x in range(margin, iw, step_x):
                    draw.text((x, y), text, font=font, fill=fill)
        elif pos == "diagonal-tiled":
            bbox = draw.textbbox((0, 0), text, font=font)
            tw2 = bbox[2] - bbox[0]
            th2 = bbox[3] - bbox[1]
            pad = int(self.font_size.get() * 1.5)
            cell = max(tw2, th2) + pad
            tile = Image.new("RGBA", (cell, cell), (0, 0, 0, 0))
            td = ImageDraw.Draw(tile)
            tx = (cell - tw2) // 2
            ty = (cell - th2) // 2
            td.text((tx, ty), text, font=font, fill=fill)
            tile = tile.rotate(35, expand=True, center=(cell // 2, cell // 2))
            tw3, th3 = tile.size
            for y in range(-th3, ih + th3, th3):
                for x in range(-tw3, iw + tw3, tw3):
                    overlay.paste(tile, (x, y), tile)
        else:
            placements = {
                "top-left": (margin, margin),
                "top-right": (iw - tw - margin, margin),
                "bottom-left": (margin, ih - th - margin),
                "bottom-right": (iw - tw - margin, ih - th - margin),
                "center": ((iw - tw) // 2, (ih - th) // 2),
            }
            xy = placements.get(pos, placements["bottom-right"])
            draw.text(xy, text, font=font, fill=fill)

        return Image.alpha_composite(img, overlay)

    def _get_font(self):
        size = self.font_size.get()
        candidates = [
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        ]
        for p in candidates:
            if os.path.exists(p):
                return ImageFont.truetype(p, size)
        return ImageFont.load_default()

    @staticmethod
    def _hex_to_rgb(h):
        h = h.lstrip("#")
        return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


if __name__ == "__main__":
    root = tk.Tk()
    app = EraseWatermarkApp(root)
    root.mainloop()
