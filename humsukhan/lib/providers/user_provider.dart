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
      // Refresh from Supabase when authenticated/available.
      final supabase = SupabaseService.instance;
      if (supabase.isReady && supabase.userId.isNotEmpty) {
        final remote = await DatabaseService.instance.fetchProfile(supabase.userId);
        if (remote != null) {
          _profile = remote;
          await prefs.setString(
            ScopedPreferences.instance.scopedKey('userProfile'),
            jsonEncode(remote.toJson()),
          );
        }
      }
    } catch (e) {
      debugPrint('User profile load error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> updateProfile(UserProfile profile) async {
    _profile = profile;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      ScopedPreferences.instance.scopedKey('userProfile'),
      jsonEncode(profile.toJson()),
    );
    try {
      await DatabaseService.instance.upsertProfile(profile);
    } catch (e) {
      debugPrint('Profile update error: $e');
    }
  }

  Future<void> clearProfile() async {
    _profile = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(ScopedPreferences.instance.scopedKey('userProfile'));
  }

  Future<String?> pickAndUploadProfilePicture(ImageSource source) async {
    _isUploadingImage = true;
    notifyListeners();
    try {
      final picked = await _picker.pickImage(source: source, imageQuality: 85, maxWidth: 1200);
      if (picked == null) return null;
      final dir = await getTemporaryDirectory();
      final localPath = '${dir.path}/profile_${DateTime.now().millisecondsSinceEpoch}.${picked.path.split('.').last}';
      await File(picked.path).copy(localPath);
      final url = await _uploadProfileImage(localPath);
      if (url != null && _profile != null) {
        await updateProfile(_profile!.copyWith(avatarUrl: url));
      }
      return url;
    } catch (e) {
      debugPrint('Profile image picker/upload error: $e');
      return null;
    } finally {
      _isUploadingImage = false;
      notifyListeners();
    }
  }

  Future<String?> _uploadProfileImage(String localPath) async {
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
}
