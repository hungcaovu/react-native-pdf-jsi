/**
 * @flow
 * @format
 */
 'use strict';

 // Note: Deep imports are required for codegen components
 // Suppressing deprecation warnings as these are the correct imports for codegen
 // @ts-ignore - React Native codegen requires these deep imports
 import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';
 // @ts-ignore - React Native codegen requires these deep imports
 import codegenNativeCommands from 'react-native/Libraries/Utilities/codegenNativeCommands';
 
 type ChangeEvent = $ReadOnly<{|
   message: ?string,
 |}>;
 
 export type NativeProps = $ReadOnly<{|
   ...ViewProps,
   path: ?string,
   page: ?Int32,
   scale: ?Float,
   minScale: ?Float,
   maxScale: ?Float,
   horizontal: ?boolean,
   enablePaging: ?boolean,
   enableRTL: ?boolean,
   enableAnnotationRendering: ?boolean,
   showsHorizontalScrollIndicator: ?boolean,
   showsVerticalScrollIndicator: ?boolean,
  scrollEnabled: ?boolean,
  enableMomentum: ?boolean,
  enableAntialiasing: ?boolean,
  enableDoubleTapZoom: ?boolean,
   fitPolicy: ?Int32,
   spacing: ?Int32,
   password: ?string,
   onChange: ?BubblingEventHandler<ChangeEvent>,
   singlePage: ?boolean,
   pdfId: ?string,
   highlightRects: ?$ReadOnlyArray<$ReadOnly<{|page: Int32, rect: string|}>>,
   skipZoneRects: ?$ReadOnlyArray<$ReadOnly<{|page: Int32, rect: string|}>>,
 |}>;

 interface NativeCommands {
  +setNativePage: (
    viewRef: React.ElementRef<ComponentType>,
    page: Int32,
  ) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
  supportedCommands: ['setNativePage'],
});

 export default codegenNativeComponent<NativeProps>('RNPDFPdfView');
