#include "sco/table.hpp"

#include <algorithm>
#include <ostream>
#include <string>

namespace sco {

namespace {

void write_padding(std::ostream& out, std::size_t count) {
    if (count > 0) {
        out << std::string(count, ' ');
    }
}

void write_cell(std::ostream& out, const std::string& value, std::size_t width, TableAlign align, bool last) {
    const auto padding = value.size() < width ? width - value.size() : 0;
    if (align == TableAlign::Right) {
        write_padding(out, padding);
        out << value;
    } else {
        out << value;
        if (!last) {
            write_padding(out, padding);
        }
    }
}

void write_row(
    std::ostream& out,
    const std::vector<TableColumn>& columns,
    const std::vector<std::size_t>& widths,
    const std::vector<std::string>& values,
    const TableOptions& options,
    bool header = false) {
    write_padding(out, options.indent);
    for (std::size_t i = 0; i < columns.size(); ++i) {
        if (i != 0) {
            write_padding(out, options.column_spacing);
        }
        const auto& value = header ? columns[i].header : (i < values.size() ? values[i] : std::string{});
        write_cell(out, value, widths[i], header ? TableAlign::Left : columns[i].align, i + 1 == columns.size());
    }
    out << '\n';
}

} // namespace

void write_table(
    std::ostream& out,
    const std::vector<TableColumn>& columns,
    const std::vector<std::vector<std::string>>& rows,
    const TableOptions& options) {
    if (columns.empty()) {
        return;
    }

    std::vector<std::size_t> widths;
    widths.reserve(columns.size());
    for (const auto& column : columns) {
        widths.push_back(column.header.size());
    }

    for (const auto& row : rows) {
        for (std::size_t i = 0; i < columns.size() && i < row.size(); ++i) {
            widths[i] = std::max(widths[i], row[i].size());
        }
    }

    if (options.leading_blank_line) {
        out << '\n';
    }
    write_row(out, columns, widths, {}, options, true);

    if (options.separator) {
        std::vector<std::string> separators;
        separators.reserve(columns.size());
        for (const auto& column : columns) {
            separators.push_back(std::string(column.header.size(), '-'));
        }
        write_row(out, columns, widths, separators, options);
    }

    for (const auto& row : rows) {
        write_row(out, columns, widths, row, options);
    }
    if (options.trailing_blank_line) {
        out << '\n';
    }
}

void write_table(
    std::ostream& out,
    const std::vector<std::string>& headers,
    const std::vector<std::vector<std::string>>& rows,
    const TableOptions& options) {
    std::vector<TableColumn> columns;
    columns.reserve(headers.size());
    for (const auto& header : headers) {
        columns.push_back(TableColumn{.header = header});
    }
    write_table(out, columns, rows, options);
}

} // namespace sco
