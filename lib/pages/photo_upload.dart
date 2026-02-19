import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

class PhotoUploadPage extends StatefulWidget {
  const PhotoUploadPage({super.key});

  @override
  State<PhotoUploadPage> createState() => _PhotoUploadPageState();
}

class _PhotoUploadPageState extends State<PhotoUploadPage>
    with SingleTickerProviderStateMixin {
  final ImagePicker _picker = ImagePicker();
  final List<XFile> _selectedPhotos = [];
  bool _isFabOpen = false;
  bool _isUploading = false;
  double _uploadProgress = 0.0;

  late AnimationController _fabAnimationController;
  late Animation<double> _fabAnimation;

  static const String _uploadUrl = 'http://192.168.100.123:3000/api/upload/';
  static const String _fileFieldName = 'photos';

  @override
  void initState() {
    super.initState();
    _fabAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fabAnimation = CurvedAnimation(
      parent: _fabAnimationController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _fabAnimationController.dispose();
    super.dispose();
  }

  // ── Selección de imágenes ──────────────────────────────────────

  Future<void> _pickFromGallery() async {
    _closeFab();
    final List<XFile> images = await _picker.pickMultiImage(imageQuality: 85);
    if (images.isNotEmpty) {
      setState(() => _selectedPhotos.addAll(images));
    }
  }

  Future<void> _pickFromCamera() async {
    _closeFab();
    final XFile? photo = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (photo != null) {
      setState(() => _selectedPhotos.add(photo));
    }
  }

  void _removePhoto(int index) {
    setState(() => _selectedPhotos.removeAt(index));
  }

  void _clearAll() {
    setState(() => _selectedPhotos.clear());
  }

  // ── FAB control ────────────────────────────────────────────────

  void _toggleFab() {
    setState(() => _isFabOpen = !_isFabOpen);
    if (_isFabOpen) {
      _fabAnimationController.forward();
    } else {
      _fabAnimationController.reverse();
    }
  }

  void _closeFab() {
    if (_isFabOpen) _toggleFab();
  }

  // ── Upload multipart ──────────────────────────────────────────

  Future<void> _uploadPhotos() async {
    if (_selectedPhotos.isEmpty) {
      _showSnackBar('No hay fotos seleccionadas', isError: true);
      return;
    }

    _closeFab();
    setState(() {
      _isUploading = true;
      _uploadProgress = 0.0;
    });

    try {
      final uri = Uri.parse(_uploadUrl);
      final request = http.MultipartRequest('POST', uri);

      // Headers opcionales (ej: auth token)
      // request.headers['Authorization'] = 'Bearer $token';

      for (int i = 0; i < _selectedPhotos.length; i++) {
        final file = _selectedPhotos[i];
        final multipartFile = await http.MultipartFile.fromPath(
          _fileFieldName, // mismo field name para todas → array en backend
          file.path,
          filename: path.basename(file.path),
        );
        request.files.add(multipartFile);

        setState(() {
          _uploadProgress = (i + 1) / _selectedPhotos.length;
        });
      }

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 10),
      );

      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200 || response.statusCode == 201) {
        _showSnackBar(
          '${_selectedPhotos.length} foto(s) subida(s) correctamente ✓',
        );
        _clearAll();
      } else {
        _showSnackBar('Error del servidor: ${response.body}', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error de conexión: $e', isError: true);
    } finally {
      setState(() => _isUploading = false);
    }
  }

  void _previewFullScreen(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            _FullScreenPreview(photos: _selectedPhotos, initialIndex: index),
      ),
    );
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Subir Fotos'),
        centerTitle: true,
        actions: [
          if (_selectedPhotos.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: 'Limpiar todo',
              onPressed: _clearAll,
            ),
        ],
      ),
      body: Stack(
        children: [
          // ── Contenido principal ──
          _selectedPhotos.isEmpty ? _buildEmptyState() : _buildPhotoGrid(),

          // ── Indicador de carga ──
          if (_isUploading) _buildUploadOverlay(),

          // ── Overlay para cerrar FAB al tocar fuera ──
          if (_isFabOpen)
            GestureDetector(
              onTap: _closeFab,
              child: Container(color: Colors.black26),
            ),
        ],
      ),
      floatingActionButton: _buildExpandableFab(theme),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.photo_library_outlined,
            size: 100,
            color: Colors.grey.shade300,
          ),
          const SizedBox(height: 16),
          Text(
            'No hay fotos seleccionadas',
            style: TextStyle(fontSize: 18, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 8),
          Text(
            'Usa el botón + para agregar fotos',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoGrid() {
    return Column(
      children: [
        // Contador
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.photo, size: 20),
              const SizedBox(width: 8),
              Text(
                '${_selectedPhotos.length} foto(s) seleccionada(s)',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        // Grid
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: _selectedPhotos.length,
            itemBuilder: (context, index) {
              return _buildPhotoTile(index);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPhotoTile(int index) {
    return GestureDetector(
      onTap: () => _previewFullScreen(index),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Imagen
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              File(_selectedPhotos[index].path),
              fit: BoxFit.cover,
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: () => _removePhoto(index),
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(4),
                child: const Icon(Icons.close, color: Colors.white, size: 16),
              ),
            ),
          ),
          // Índice
          Positioned(
            bottom: 4,
            left: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${index + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUploadOverlay() {
    return Container(
      color: Colors.black45,
      child: Center(
        child: Card(
          margin: const EdgeInsets.all(32),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 20),
                Text(
                  'Subiendo fotos... ${(_uploadProgress * 100).toInt()}%',
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: _uploadProgress,
                  borderRadius: BorderRadius.circular(8),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExpandableFab(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Opciones desplegables (aparecen hacia arriba)
        ..._buildFabOptions(theme),
        const SizedBox(height: 8),
        // Botón principal
        FloatingActionButton(
          onPressed: _toggleFab,
          child: AnimatedBuilder(
            animation: _fabAnimation,
            builder: (_, child) {
              return Transform.rotate(
                angle: _fabAnimation.value * 0.75 * 3.14159,
                child: child,
              );
            },
            child: const Icon(Icons.add, size: 28),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildFabOptions(ThemeData theme) {
    final options = <_FabOption>[
      _FabOption(
        icon: Icons.photo_library_rounded,
        label: 'Galería',
        onTap: _pickFromGallery,
        color: Colors.deepPurple,
      ),
      _FabOption(
        icon: Icons.camera_alt_rounded,
        label: 'Cámara',
        onTap: _pickFromCamera,
        color: Colors.teal,
      ),
      if (_selectedPhotos.isNotEmpty)
        _FabOption(
          icon: Icons.cloud_upload_rounded,
          label: 'Enviar al servidor',
          onTap: _uploadPhotos,
          color: Colors.blue,
        ),
    ];

    return options.asMap().entries.map((entry) {
      final i = entry.key;
      final option = entry.value;
      return ScaleTransition(
        scale: CurvedAnimation(
          parent: _fabAnimationController,
          curve: Interval(
            (options.length - 1 - i) * 0.15,
            1.0,
            curve: Curves.easeOut,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Label chip
              Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                color: theme.colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Text(
                    option.label,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Mini FAB
              FloatingActionButton.small(
                heroTag: 'fab_option_$i',
                backgroundColor: option.color,
                onPressed: option.onTap,
                child: Icon(option.icon, color: Colors.white),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }
}

// ── Modelo auxiliar para opciones del FAB ─────────────────────────

class _FabOption {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  const _FabOption({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.color,
  });
}

// ── Previsualización a pantalla completa ──────────────────────────

class _FullScreenPreview extends StatelessWidget {
  final List<XFile> photos;
  final int initialIndex;

  const _FullScreenPreview({required this.photos, required this.initialIndex});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text('${initialIndex + 1} / ${photos.length}'),
        centerTitle: true,
      ),
      body: PageView.builder(
        controller: PageController(initialPage: initialIndex),
        itemCount: photos.length,
        itemBuilder: (context, index) {
          return InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: Center(
              child: Image.file(File(photos[index].path), fit: BoxFit.contain),
            ),
          );
        },
      ),
    );
  }
}
