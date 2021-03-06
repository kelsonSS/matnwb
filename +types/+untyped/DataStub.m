classdef DataStub
    properties(SetAccess=private)
        filename;
        path;
        dims;
    end
    
    methods
        function obj = DataStub(filename, path)
            obj.filename = filename;
            obj.path = path;
            fid = H5F.open(obj.filename, 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
            did = H5D.open(fid, obj.path);
            sid = H5D.get_space(did);
            [~, obj.dims, ~] = H5S.get_simple_extent_dims(sid);
            H5S.close(sid);
            H5D.close(did);
            H5F.close(fid);
        end
        
        function sid = get_space(obj)
            fid = H5F.open(obj.filename);
            did = H5D.open(fid, obj.path);
            sid = H5D.get_space(did);
            H5D.close(did);
            H5F.close(fid);
        end
        
        function nd = ndims(obj)
            nd = length(obj.dims);
        end
        
        function num = numel(obj)
            num = prod(obj.dims);
        end
        
        %can be called without arg, with H5ML.id, or (dims, offset, stride)
        function data = load_h5_style(obj, varargin)
            %LOAD  Read data from HDF5 dataset.
            %   DATA = LOAD_H5_STYLE() retrieves all of the data.
            %
            %   DATA = LOAD_H5_STYLE(SPACE) Load data specified by HDF5 SPACE
            %
            %   DATA = LOAD_H5_STYLE(START,COUNT) reads a subset of data. START is
            %   the one-based index of the first element to be read.
            %   COUNT defines how many elements to read along each dimension.  If a
            %   particular element of COUNT is Inf, data is read until the end of the
            %   corresponding dimension.
            %
            %   DATA = LOAD_H5_STYLE(START,COUNT,STRIDE) reads a strided subset of
            %   data. STRIDE is the inter-element spacing along each
            %   data set extent and defaults to one along each extent.
            fid = [];
            did = [];
            if length(varargin) == 1
                fid = H5F.open(obj.filename);
                did = H5D.open(fid, obj.path);
                
                sid = varargin{1};
                % in event of multiple hyperslab selections, return as a cell array
                nb = H5S.get_select_hyper_nblocks(sid);
                % format blocklist to cell array of region indices separated by
                % block
                bl = mat2cell(H5S.get_select_hyper_blocklist(sid, 0, nb) .',...
                    repmat(2, 1, nb), obj.ndims());
                
                data = cell(nb,1);
                % go through each hyperslab selection and read data from H5D,
                % populating cell array of hyperslab selections
                selsid = H5S.create('H5S_SIMPLE');
                H5S.extent_copy(selsid, sid);
                for i=1:nb
                    selsz = diff(bl{i})+1;
                    sizesid = H5S.create_simple(obj.ndims(), selsz, selsz);
                    H5S.select_hyperslab(selsid, 'H5S_SELECT_SET',...
                        bl{i}(1,:), [], [], selsz);
                    data{i} = H5D.read(did, 'H5ML_DEFAULT', sizesid, selsid, 'H5P_DEFAULT') .';
                end
                H5S.close(selsid);
                
                if isscalar(data)
                    data = data{1};
                end
            else
                data = h5read(obj.filename, obj.path, varargin{:});
                
                % dataset strings are defaulted to cell arrays regardless of size
                if iscellstr(data) && isscalar(data)
                    data = data{1};
                end
            end
            
            if isstruct(data)
                if length(varargin) ~= 1
                    fid = H5F.open(obj.filename);
                    did = H5D.open(fid, obj.path);
                end
                fsid = H5D.get_space(did);
                data = H5D.read(did, 'H5ML_DEFAULT', fsid, fsid,...
                    'H5P_DEFAULT');
                data = io.parseCompound(did, data);
                H5S.close(fsid);
            end
            if ~isempty(fid)
                H5F.close(fid);
            end
            if ~isempty(did)
                H5D.close(did);
            end
        end
        
        function data = load(obj, varargin)
            %LOAD  Read data from HDF5 dataset with syntax more similar to
            %core MATLAB
            %   DATA = LOAD() retrieves all of the data.
            %
            %   DATA = LOAD(INDEX)
            %
            %   DATA = LOAD(START,END) reads a subset of data.
            %   START and END are 1-based index indicating the beginning
            %   and end indices of the region to read
            %
            %   DATA = LOAD(START,STRIDE,END) reads a strided subset of
            %   data. STRIDE is the inter-element spacing along each
            %   data set extent and defaults to one along each extent.
            
            if isempty(varargin)
                data = obj.load_h5_style();
            elseif length(varargin) == 1
                region = misc.idx2h5(varargin{1}, fliplr(obj.dims), 'preserve');
                sid = obj.get_space();
                H5S.select_none(sid);
                for i=1:length(region)
                    reg = region{i};
                    H5S.select_hyperslab(sid, 'H5S_SELECT_OR', reg(1,:),...
                        [], [], diff(reg, 1, 1)+1);
                end
                data = obj.load_h5_style(sid);
                H5S.close(sid);
            else
                if length(varargin) == 2
                    START = varargin{1};
                    END = varargin{2};
                    STRIDE = ones(size(START));
                elseif length(varargin) == 3
                    START = varargin{1};
                    STRIDE = varargin{2};
                    END = varargin{3};
                end
                
                for i = 1:length(END)
                    if strcmp(END(i), 'end')
                        count(i) = Inf;
                    else
                        count(i) = floor((END(i) - START(i)) / STRIDE(i) + 1);
                    end
                end
                data = obj.load_h5_style(START, count, STRIDE);
            end
        end
        
        
        function refs = export(obj, fid, fullpath, refs)
            %Check for compound data type refs
            srcfid = H5F.open(obj.filename);
            srcdid = H5D.open(srcfid, obj.path);
            srctid = H5D.get_type(srcdid);
            srcsid = H5D.get_space(srcdid);
            ref_i = false;
            char_i = false;
            membname = {};
            ref_tid = {};
            if H5T.get_class(srctid) == H5ML.get_constant_value('H5T_COMPOUND')
                ncol = H5T.get_nmembers(srctid);
                ref_i = false(ncol, 1);
                membname = cell(ncol, 1);
                char_i = false(ncol, 1);
                ref_tid = cell(ncol, 1);
                refTypeConst = H5ML.get_constant_value('H5T_REFERENCE');
                strTypeConst = H5ML.get_constant_value('H5T_STRING');
                for i = 1:ncol
                    membname{i} = H5T.get_member_name(srctid, i-1);
                    subclass = H5T.get_member_class(srctid, i-1);
                    subtid = H5T.get_member_type(srctid, i-1);
                    char_i(i) = subclass == strTypeConst && ...
                        ~H5T.is_variable_str(subtid);
                    if subclass == refTypeConst
                        ref_i(i) = true;
                        ref_tid{i} = subtid;
                    end
                end
            end
            
            %manually load the data struct
            if any(ref_i)
                %This requires loading the entire table.
                %Due to this HDF5 library's inability to delete/update
                %dataset data, this is unfortunately required.
                ref_tid = ref_tid(~cellfun('isempty', ref_tid));
                data = H5D.read(srcdid);
                
                refNames = membname(ref_i);
                for i=1:length(refNames)
                    data.(refNames{i}) = io.parseReference(srcdid, ref_tid{i}, ...
                        data.(refNames{i}));
                end
                
                strNames = membname(char_i);
                for i=1:length(strNames)
                    s = data.(strNames{i}) .';
                    data.(strNames{i}) = mat2cell(s, ones(size(s,1),1));
                end
                
                io.writeCompound(fid, fullpath, data);
            else
                %copy data over and return destination
                ocpl = H5P.create('H5P_OBJECT_COPY');
                lcpl = H5P.create('H5P_LINK_CREATE');
                H5O.copy(srcfid, obj.path, fid, fullpath, ocpl, lcpl);
                H5P.close(ocpl);
                H5P.close(lcpl);
            end
            H5T.close(srctid);
            H5S.close(srcsid);
            H5D.close(srcdid);
            H5F.close(srcfid);
        end
    end
end
