flatpak-builder --repo=repo --force-clean build-dir com.github.magillos.cable.yaml;
flatpak build-bundle --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo repo com.github.magillos.cable.flatpak com.github.magillos.cable;
#flatpak build-bundle repo com.github.magillos.cable.flatpak com.github.magillos.cable;
flatpak install --user com.github.magillos.cable.flatpak;
flatpak run com.github.magillos.cable;

