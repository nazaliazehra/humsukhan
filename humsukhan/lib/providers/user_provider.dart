import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/models.dart';
import '../services/supabase_service.dart';
import '../services/database_service.dart';
import '../services/scoped_preferences.dart';

class UserProvider extends ChangeNotifier {
  UserProfile? _profile;
  bool _isLoading = false;
  bool _isUploadingImage = false;
  final ImagePicker _picker = ImagePicker();

  UserProfile? get profile => _profile;
  bool get isLoading => _isLoading;
  bool get isUploadingImage => _isUploadingImage;
  bool get hasProfile => _profile != null;

  UserProvider() {
    _loadProfile();
  }

  /// Reload profile data for the current user scope.
  /// Called by main.dart when the authenticated user changes.
  Future<void> reload() => _loadProfile();

  Future<void> _loadProfile() async {
    _isLoading = true;
    notifyListeners();
    try {
      // Load from local first
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(ScopedPreferences.instance.scopedKey('userProfile'));
      if (json != null) {
        _profile = UserProfile.fromJson(jsonDecode(json));
      }

      // Sync from Supabase if authenticated
      if (SupabaseService.instance.isAuthenticated) {
        final userId = SupabaseService.instance.userId;
        final cloudProfile = await DatabaseService.instance.fetchProfile(userId);
        if (cloudProfile != null) {
          _profile = cloudProfile;
          // Update local cache
          await prefs.setString(
            ScopedPreferences.instance.scopedKey('userProfile'),
            jsonEncode(cloudProfile.toJson()),
          );
        } else if (_profile != null) {
          // Push local profile to cloud
          await DatabaseService.instance.upsertProfile(_profile!);
        }
      }
    } catch (e) {
      debugPrint('Error loading profile: $e');
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> saveProfile(UserProfile profile) async {
    _profile = profile;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      ScopedPreferences.instance.scopedKey('userProfile'),
      jsonEncode(profile.toJson()),
    );

    // Sync to Supabase if authenticated
    if (SupabaseService.instance.isAuthenticated) {
      await DatabaseService.instance.upsertProfile(profile);
    }

    notifyListeners();
  }

  Future<void> createProfile({
    required String name,
    String avatarEmoji = '👤',
    String preferredLanguage = 'English',
    String tutorName = 'Sam',
  }) async {
    final profile = UserProfile(
      name: name,
      avatarEmoji: avatarEmoji,
      preferredLanguage: preferredLanguage,
      tutorName: tutorName,
    );
    await saveProfile(profile);
  }

  // ── Profile Image Management ──────────────────────────────────────

  /// Pick an image from the specified source.
  /// Returns the picked [XFile] or null if the user cancelled.
  Future<XFile?> pickImage({ImageSource source = ImageSource.gallery}) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      return image;
    } catch (e) {
      debugPrint('Error picking image: $e');
      return null;
    }
  }

  /// Save a picked image locally and update the profile.
  ///
  /// The image is saved to the app's documents directory with a stable
  /// filename based on the user's profile ID. If the user is authenticated,
  /// the image is also uploaded to Supabase Storage.
  Future<bool> saveProfileImage(XFile pickedFile) async {
    if (_profile == null) return false;

    _isUploadingImage = true;
    notifyListeners();

    try {
      // Save locally
      final localPath = await _saveImageLocally(pickedFile);
      if (localPath == null) {
        _isUploadingImage = false;
        notifyListeners();
        return false;
      }

      // Update profile with local path first (so UI updates immediately)
      final updatedProfile = _profile!.copyWith(avatarUrl: localPath);
      await saveProfile(updatedProfile);

      // If authenticated, also try to upload to Supabase Storage
      if (SupabaseService.instance.isAuthenticated) {
        final publicUrl = await _uploadToSupabase(localPath);
        if (publicUrl != null) {
          // Update with the public URL so it works across devices
          final cloudProfile = _profile!.copyWith(avatarUrl: publicUrl);
          await saveProfile(cloudProfile);
        }
        // If upload fails, we still have the local copy — don't break
      }

      _isUploadingImage = false;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error saving profile image: $e');
      _isUploadingImage = false;
      notifyListeners();
      return false;
    }
  }

  /// Remove the profile picture and revert to the emoji avatar.
  Future<void> removeProfileImage() async {
    if (_profile == null || !_profile!.hasAvatarImage) return;

    // Delete local file if it exists
    try {
      final localPath = _profile!.avatarUrl;
      if (localPath != null && !localPath.startsWith('http')) {
        final file = File(localPath);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      debugPrint('Error deleting local profile image: $e');
    }

    // Update profile to clear avatarUrl
    final updatedProfile = _profile!.copyWith(clearAvatarUrl: true);
    await saveProfile(updatedProfile);
  }

  /// Save the picked image to the app's documents directory.
  /// Returns the local file path, or null on failure.
  Future<String?> _saveImageLocally(XFile pickedFile) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final imagesDir = Directory('${appDir.path}/profile_images');
      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }

      // Use a stable filename based on profile ID
      final extension = pickedFile.path.split('.').last;
      final localPath = '${imagesDir.path}/profile_${_profile!.id}.$extension';

      // Copy the picked file to our local directory
      await File(pickedFile.path).copy(localPath);
      return localPath;
    } catch (e) {
      debugPrint('Error saving image locally: $e');
      return null;
    }
  }

  /// Upload the profile image to Supabase Storage.
  /// Returns the public URL on success, or null on failure.
  Future<String?> _uploadToSupabase(String localPath) async {
    try {
      final supabase = SupabaseService.instance;
      if (!supabase.isReady || supabase.client == null) return null;

      final file = File(localPath);
      if (!await file.exists()) return null;

      final userId = supabase.userId;
      if (userId.isEmpty) return null;

      // Upload to Supabase Storage bucket 'profile-images'
      final bytes = await file.readAsBytes();
      final fileExtension = localPath.split('.').last;
      final storagePath = '$userId/profile.$fileExtension';

      await supabase.client!.storage
          .from('profile-images')
          .uploadBinary(
            storagePath,
            bytes,
            fileOptions: FileOptions(upsert: true),
          );

      // Get the public URL
      final publicUrl = supabase.client!.storage
          .from('profile-images')
          .getPublicUrl(storagePath);

      debugPrint('Profile image uploaded: $publicUrl');
      return publicUrl;
    } catch (e) {
      debugPrint('Supabase upload error: $e');
      return null;
    }
  }

  /// Get the effective avatar URL — either the stored image path or null
  /// (meaning use the emoji fallback).
  String? get avatarImageUrl => _profile?.avatarUrl;
}
