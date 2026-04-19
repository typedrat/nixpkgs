{
  lib,
  stdenv,
  autoPatchelfHook,
  bun,
  copyDesktopItems,
  electron_41,
  makeDesktopItem,
  makeWrapper,
  models-dev,
  nodejs,
  opencode,
  commandLineArgs ? "",
}:

let
  electron = electron_41;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "opencode-desktop";
  inherit (opencode)
    version
    src
    node_modules
    patches
    ;

  nativeBuildInputs =
    [
      bun
      nodejs
      makeWrapper
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      copyDesktopItems
      autoPatchelfHook
    ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.cc.lib
  ];

  autoPatchelfIgnoreMissingDeps = [
    "libc.musl-*.so.*"
  ];

  env = {
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
    MODELS_DEV_API_JSON = "${models-dev}/dist/_api.json";
    OPENCODE_DISABLE_MODELS_FETCH = true;
    OPENCODE_VERSION = finalAttrs.version;
    OPENCODE_CHANNEL = "latest";
  };

  postPatch = ''
    # Relax bun version check (same as base opencode package)
    substituteInPlace packages/script/src/index.ts \
      --replace-fail 'throw new Error(`This script requires bun@''${expectedBunVersionRange}' \
                     'console.warn(`Warning: This script requires bun@''${expectedBunVersionRange}'

    # Disable auto-updater since updates are managed by nix
    substituteInPlace packages/desktop/src/main/constants.ts \
      --replace-fail 'app.isPackaged && CHANNEL !== "dev"' "false"
  '';

  buildPhase = ''
    runHook preBuild

    # Set up workspace from shared node_modules FOD
    cp -a ${finalAttrs.node_modules}/{node_modules,packages} .
    chmod -R u+w node_modules packages
    patchShebangs node_modules
    patchShebangs packages/*/node_modules

    export PATH="$PWD/packages/desktop/node_modules/.bin:$PWD/node_modules/.bin:$PATH"

    # Copy production icons into resources/ for electron-builder
    cp -R packages/desktop/icons/prod packages/desktop/resources/icons

    # Build the opencode node server (consumed via virtual:opencode-server in electron-vite)
    (cd packages/opencode && bun --bun ./script/build-node.ts)

    # Build electron app with electron-vite
    cd packages/desktop
    electron-vite build

    # Package with electron-builder using system electron.
    # On Linux, electron-builder only reads from electronDist, so we can pass
    # the nix store path directly. On Darwin, it modifies the .app bundle
    # (Info.plist, code signing), so a writable copy is required.
    ${lib.optionalString stdenv.hostPlatform.isDarwin ''
      cp -r ${electron.dist} electron-dist
      chmod -R u+w electron-dist
    ''}
    electron-builder --dir \
      --config electron-builder.config.ts \
      -c.electronDist=${if stdenv.hostPlatform.isDarwin then "electron-dist" else electron.dist} \
      -c.electronVersion=${electron.version} \
      -c.asarUnpack="**/*.node"
    cd ../..

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      mkdir -p $out/share/opencode-desktop
      cp -r packages/desktop/dist/*-unpacked/{locales,resources{,.pak}} \
        $out/share/opencode-desktop

      install -Dm644 packages/desktop/icons/prod/icon.png \
        $out/share/icons/hicolor/512x512/apps/opencode-desktop.png

      makeWrapper ${lib.getExe electron} $out/bin/OpenCode \
        --add-flags $out/share/opencode-desktop/resources/app.asar \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}" \
        ${lib.optionalString (commandLineArgs != "") "--add-flags ${lib.escapeShellArg commandLineArgs}"} \
        --set-default ELECTRON_IS_DEV 0 \
        --set-default ELECTRON_FORCE_IS_PACKAGED 1 \
        --inherit-argv0
    ''}

    ${lib.optionalString stdenv.hostPlatform.isDarwin ''
      mkdir -p $out/Applications
      cp -r packages/desktop/dist/mac*/"OpenCode.app" "$out/Applications/OpenCode.app"
      makeWrapper "$out/Applications/OpenCode.app/Contents/MacOS/OpenCode" $out/bin/OpenCode \
        ${lib.optionalString (commandLineArgs != "") "--add-flags ${lib.escapeShellArg commandLineArgs}"}
    ''}

    runHook postInstall
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "opencode-desktop";
      desktopName = "OpenCode";
      comment = finalAttrs.meta.description;
      exec = "OpenCode %U";
      icon = "opencode-desktop";
      terminal = false;
      categories = [ "Development" ];
      mimeTypes = [ "x-scheme-handler/opencode" ];
    })
  ];

  meta = {
    description = "AI coding agent desktop client";
    homepage = "https://opencode.ai";
    inherit (electron.meta) platforms;
    license = lib.licenses.mit;
    mainProgram = "OpenCode";
    maintainers = with lib.maintainers; [ xiaoxiangmoe ];
  };
})
