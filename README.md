# Cores

A clean, lightweight menu bar monitor for Macs with Apple silicon.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/panel-dark.png">
    <img src="docs/panel-light.png" width="600" alt="The Cores dropdown: cards for the CPU, GPU, memory, disk, battery and fans, each with a one-minute chart, and a bar for every core">
  </picture>
</p>

Cores shows your CPU load and temperature in the menu bar. In Settings → Menu bar you can show just one of them to save room, or add your battery's charge on a laptop. Click it for a card for each part of your Mac, each with a chart of the last minute:

- **CPU**: load, each core type, and temperature, plus **every core at a glance**
- **GPU**: how busy it is, how much memory it's using, and temperature
- **Memory**: how much of your unified memory is in use, broken down like Activity Monitor, and memory pressure
- **Disk**: free space, read and write speed, and SSD temperature
- **Battery** (laptops): charge, whether it's plugged in and charging, power draw, cycle count and temperature
- **Fans**: the speed of each fan

It uses almost no CPU itself and keeps itself up to date.

## Download

**[Download Cores](https://github.com/Jam0r85/Cores/releases/latest/download/Cores.dmg)**, open it and drag Cores into your Applications folder. To have it start when you log in, open the dropdown and choose Settings → Open at login.

Requires a Mac with Apple silicon and macOS 14 or later.
